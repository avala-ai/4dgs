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

import 'dart:convert';
import 'dart:typed_data';

import 'chunk_decoder.dart';
import 'exceptions.dart';
import 'indexed_reader.dart';
import 'keyframe_delta.dart';
import 'opcode.dart';
import 'provenance.dart' show lengthUnitMetres;
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
  static const int _detailedNoteLimit = 64;
  static const int _detailedFindingLimit = 256;

  final List<FourdgsFinding> findings = <FourdgsFinding>[];
  int _detailedFindings = 0;
  int _omittedFindings = 0;
  int? _omittedFindingAt;
  FourdgsSeverity _worstOmitted = FourdgsSeverity.note;
  int _detailedNotes = 0;
  int _omittedNotes = 0;
  int? _omittedNoteAt;

  void _retain(FourdgsFinding finding) {
    if (_detailedFindings < _detailedFindingLimit) {
      findings.add(finding);
      _detailedFindings += 1;
      return;
    }
    _omittedFindings += 1;
    if (finding.severity.index > _worstOmitted.index) {
      _worstOmitted = finding.severity;
    }
    final summary = FourdgsFinding(
      _worstOmitted,
      '$_omittedFindings additional validation findings omitted after the '
      'first $_detailedFindingLimit; validation still checked every record',
    );
    if (_omittedFindingAt == null) {
      _omittedFindingAt = findings.length;
      findings.add(summary);
    } else {
      findings[_omittedFindingAt!] = summary;
    }
  }

  void error(String message) =>
      _retain(FourdgsFinding(FourdgsSeverity.error, message));

  void warn(String message) =>
      _retain(FourdgsFinding(FourdgsSeverity.warning, message));

  void note(String message) {
    if (_detailedNotes < _detailedNoteLimit) {
      _retain(FourdgsFinding(FourdgsSeverity.note, message));
      _detailedNotes += 1;
      return;
    }
    _omittedNotes += 1;
    final finding = FourdgsFinding(
      FourdgsSeverity.note,
      '$_omittedNotes additional record notes omitted after the first '
      '$_detailedNoteLimit; validation still checked every record',
    );
    if (_omittedNoteAt == null) {
      if (_detailedFindings < _detailedFindingLimit) {
        _omittedNoteAt = findings.length;
        findings.add(finding);
        _detailedFindings += 1;
      } else {
        _retain(finding);
      }
    } else {
      findings[_omittedNoteAt!] = finding;
    }
  }

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
  }) => _retain(
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

typedef _StateInterval = ({double t0, double t1, int offset});
typedef _SummaryOffsetAt = ({FourdgsSummaryOffset value, int offset});

/// Offset lists are diagnostic samples, not a second record table. The framing
/// walk already retains a bounded table and replays every omitted record; these
/// lists need only enough entries to make an error actionable.
const int _retainedOffsetLimit = 64;

/// Every check, in the Python validator's order.
///
/// Nothing here holds the file. The Python, Rust, TypeScript and C++ validators
/// all take the whole thing as a byte array, and this one deliberately does not:
/// it is the only one of the six whose entry point is a [FourdgsReadable], and a
/// validator that reads a file to check a file is exactly the API AGENTS.md §1
/// calls wrong. So the framing walk supplies the record table, each record's
/// content is fetched by its own range when a check needs it, the summary
/// checksum is run a block at a time, and the decode passes hold one chunk or
/// one band. What a multi-gigabyte scene costs to validate is the largest single
/// chunk in it.
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
  int footerOffset = -1;
  int footerLength = -1;
  int firstOpcode = -1;
  int chunkCount = 0;
  int counted = 0;
  final List<FourdgsChunkIndexEntry> index = <FourdgsChunkIndexEntry>[];
  final List<int> indexFrameOffsets = <int>[];
  final List<int> summaryFrameOffsets = <int>[];
  final List<int> summaryOffsetFrameOffsets = <int>[];
  // Where each entry's own Chunk Index record sits, so a finding about entry `i`
  // names the byte the reader would name for the same fault.
  final List<int> indexRecordOffsets = <int>[];
  final List<_SummaryOffsetAt> summaryOffsets = <_SummaryOffsetAt>[];
  bool indexLimitReported = false;
  bool summaryOffsetLimitReported = false;
  // Pairing needs only the source id and its declared payload length. Parsed
  // descriptors (especially their keyframe arrays and strings) are released
  // before the next record is read.
  final Map<int, int> audioSources = <int, int>{};
  final Map<int, int> audioData = <int, int>{};
  bool firstChunkSeen = false;
  bool legacyAudioSeen = false;
  // A front-matter refusal makes the reader passes below pointless: the reader
  // would refuse the same record for the same reason at the same byte, and a
  // report that says it twice is a report a reader has to read twice.
  bool frontMatterRefused = false;

  try {
    await for (final FourdgsFrame frame in walkFourdgsFrames(source, walk)) {
      // The record the file was cut inside. The walk lists it — the declared
      // length that runs off the end is the whole fault — but there is nothing
      // to parse, and the sentence is the one a cursor would have raised
      // reading it, so the other validators' output is unchanged.
      if (frame.offset + frame.total > walk.size) {
        report.error(
          'stopped reading: need ${frame.length} bytes at offset '
          '${frame.offset + recordHeaderBytes}, '
          '${walk.size - frame.offset - recordHeaderBytes} remain',
        );
        break;
      }
      if (firstOpcode < 0) firstOpcode = frame.opcode;
      seen.add(frame.opcode);
      if (frame.opcode == opChunkIndex ||
          frame.opcode == opStatistics ||
          frame.opcode == opSummaryOffset) {
        if (summaryFrameOffsets.length < _retainedOffsetLimit) {
          summaryFrameOffsets.add(frame.offset);
        }
      }
      if (frame.opcode == opSummaryOffset) {
        if (summaryOffsetFrameOffsets.isEmpty) {
          summaryOffsetFrameOffsets.add(frame.offset);
        }
      }
      if (isSpecifiedOpcode(frame.opcode) &&
          !isLegalTopLevelOpcode(frame.opcode)) {
        report.error(
          '${opcodeName(frame.opcode)} (0x${frame.opcode.toRadixString(16).padLeft(2, "0")}) '
          'is not legal as a top-level record',
        );
      }
      // A record whose own body will not parse is a finding rather than an
      // abort: the point of a validator is to say everything that is wrong with
      // a file, not the first thing.
      switch (frame.opcode) {
        case opHeader:
          try {
            header = FourdgsHeader.parse(
              await _bytesOf(source, frame),
              fileOffset: frame.offset + recordHeaderBytes,
            );
          } on FourdgsException catch (error) {
            // Named against *this* Header, not against the first record with
            // this opcode. Nothing in the framing forbids a second one, and a
            // refusal placed at the first would send its holder to a record
            // that is perfectly fine.
            frontMatterRefused |= _refuse(
              report,
              error,
              frame.offset,
              'the Header record',
              'Header does not parse: ',
            );
          }
        case opQuantization:
          try {
            quantization = FourdgsQuantization.parse(
              await _bytesOf(source, frame),
              fileOffset: frame.offset + recordHeaderBytes,
            );
          } on FourdgsException catch (error) {
            frontMatterRefused |= _refuse(
              report,
              error,
              frame.offset,
              'the Quantization record',
              'Quantization does not parse: ',
            );
          }
        case opWindowTable:
          // Read for the decode pass below, quietly: the Python validator does
          // not report this record, and a finding it does not have is a
          // disagreement about a file.
          try {
            windows =
                FourdgsWindowTable.parse(await _bytesOf(source, frame)).windows;
          } on FourdgsException catch (error) {
            report.error('Window Table does not parse: ${_say(error)}');
          }
        case opChunk:
        case opDeltaChunk:
          firstChunkSeen = true;
          chunkCount += 1;
          try {
            if (frame.opcode == opChunk) {
              // The first twenty-four bytes, not the record: a chunk is where a
              // file keeps its weight, and all this pass wants from one is the
              // count it declares. What is *in* it is checked by decoding it,
              // one chunk at a time, further down.
              final parsed = parseChunkInterval(
                await _bytesOf(source, frame, most: chunkFixedHeadBytes),
                fileOffset: frame.offset + recordHeaderBytes,
              );
              counted += parsed.count;
            } else {
              final FourdgsCursor cursor = FourdgsCursor(
                await _bytesOf(source, frame, most: 16),
              );
              final double t0 = cursor.f64();
              final double t1 = cursor.f64();
              refuseUnusableInterval(
                t0,
                t1,
                frame.offset + recordHeaderBytes,
                'Delta Chunk',
              );
            }
          } on FourdgsException catch (error) {
            report.error('chunk $chunkCount does not parse: ${_say(error)}');
          }
        case opChunkIndex:
          if (indexFrameOffsets.length < _retainedOffsetLimit) {
            indexFrameOffsets.add(frame.offset);
          }
          if (index.length >= maxChunkIndexEntries) {
            if (!indexLimitReported) {
              report.error(
                'the chunk index holds more than $maxChunkIndexEntries entries; '
                'later entries are framed but not retained',
              );
              indexLimitReported = true;
            }
          } else {
            try {
              index.add(
                FourdgsChunkIndexEntry.parse(
                  await _bytesOf(source, frame),
                  fileOffset: frame.offset + recordHeaderBytes,
                ),
              );
              indexRecordOffsets.add(frame.offset);
            } on FourdgsException catch (error) {
              report.error(
                'a chunk index entry does not parse: ${_say(error)}',
              );
            }
          }
        case opSummaryOffset:
          try {
            final FourdgsSummaryOffset parsed = FourdgsSummaryOffset.parse(
              await _bytesOf(source, frame),
            );
            if (summaryOffsets.length < maxChunkIndexEntries) {
              summaryOffsets.add((value: parsed, offset: frame.offset));
            } else if (!summaryOffsetLimitReported) {
              report.error(
                'validation retains at most $maxChunkIndexEntries Summary '
                'Offset declarations; later records are still framed',
              );
              summaryOffsetLimitReported = true;
            }
          } on FourdgsException catch (error) {
            report.error('a Summary Offset does not parse: ${_say(error)}');
          }
        case opFooter:
          try {
            footer = FourdgsFooter.parse(
              await _bytesOf(source, frame, most: footerFixedBytes),
            );
            footerOffset = frame.offset;
            footerLength = frame.length;
          } on FourdgsException catch (error) {
            report.error('Footer does not parse: ${_say(error)}');
          }
        case opAudio:
          try {
            await _checkLegacyAudioHead(source, frame);
            if (legacyAudioSeen) {
              report.error(
                'the file carries more than one legacy Audio record',
              );
            }
            legacyAudioSeen = true;
          } on FourdgsException catch (error) {
            report.error('legacy Audio does not parse: ${_say(error)}');
          }
        case opAudioSource:
          try {
            final FourdgsAudioSourceRecord parsed =
                FourdgsAudioSourceRecord.parse(await _bytesOf(source, frame));
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
            final FourdgsHeader? parsedHeader = header;
            if (parsedHeader != null) {
              for (int i = 0; i < parsed.keyframes.length; i++) {
                final double t = parsed.keyframes[i].time;
                if (t < 0 || t > parsedHeader.durationSec) {
                  report.error(
                    'Audio Source id ${parsed.sourceId} keyframe $i time $t is '
                    'outside [0, ${parsedHeader.durationSec}]',
                  );
                }
              }
            }
            audioSources[parsed.sourceId] = parsed.dataLength;
          } on FourdgsException catch (error) {
            report.error('Audio Source does not parse: ${_say(error)}');
          }
        case opAudioData:
          try {
            // The id and the declared payload length, not the payload: an
            // embedded soundtrack is megabytes, and what this pass compares is
            // the length against the Audio Source's.
            final ({int sourceId, int length}) parsed = _audioDataHead(
              await _bytesOf(source, frame, most: audioDataHeadBytes),
              frame,
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
            audioData[parsed.sourceId] = parsed.length;
          } on FourdgsException catch (error) {
            report.error('Audio Data does not parse: ${_say(error)}');
          }
        case opAttachment:
          try {
            await _checkAttachmentHead(source, frame);
          } on FourdgsException catch (error) {
            report.error(
              'the Attachment record at byte ${frame.offset} does not parse: '
              '${_say(error)}',
            );
          }
        default:
          _noteUnread(report, frame);
      }
    }
    // Bytes after the last whole record that are neither a record nor the
    // closing magic. The same sentence the record iterator raises, because it is
    // the same fault.
    final FourdgsCut? trailing = walk.cut;
    if (trailing != null && !trailing.insideARecord) {
      report.error(
        'stopped reading: ${walk.size - trailing.at} trailing bytes are '
        'neither a record nor the closing magic',
      );
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
  if (walk.count(opHeader) == 0) report.error('no Header record');
  if (walk.count(opQuantization) == 0) report.error('no Quantization record');
  if (walk.count(opFooter) == 0) report.error('no Footer record');
  if (walk.count(opFooter) > 1) {
    report.error(
      'the file carries ${walk.count(opFooter)} Footer records (the first is at '
      'byte ${walk.first(opFooter)!.offset}); the Footer must appear exactly '
      'once as the final record',
    );
  }
  if (walk.count(opFooter) > 0 &&
      walk.last != null &&
      walk.last!.opcode != opFooter) {
    final FourdgsFrame last = walk.last!;
    report.error(
      'the Footer at byte ${walk.first(opFooter)!.offset} is followed by '
      '${opcodeName(last.opcode)} at byte ${last.offset}; the Footer must be '
      'the final record',
    );
  }

  // Which chunk shape the rest of this validator is entitled to assume. A
  // `keyframe-delta` file's Chunks are keyframes and its Delta Chunks are
  // differences against them, so several checks below are about the
  // `gaussian-birth` shape and about nothing else. Read from the Header rather
  // than guessed from the records, because a file that carries Delta Chunks and
  // does not say so is itself a fault.
  final bool keyframeDelta = header?.temporalModel == 'keyframe-delta';

  if (header != null && !keyframeDelta && seen.contains(opDeltaChunk)) {
    report.error(
      'a Delta Chunk is only legal under the keyframe-delta temporal model; '
      'the Header declares ${header.temporalModel}',
    );
  }
  if (header != null && keyframeDelta) {
    await _checkFramedTiling(source, walk, header.durationSec, report);
  }

  if (header != null) {
    const int knownHeaderFlags =
        headerFlagHasAudio | headerFlagChunksCompressed;
    final int reservedFlags = header.flags & ~knownHeaderFlags;
    if (reservedFlags != 0) {
      report.error(
        'Header flags set reserved bits 0x${reservedFlags.toRadixString(16)}; '
        'only bits 0 (audio) and 1 (chunks compressed) are defined',
      );
    }
    if (quantization != null) {
      _checkShBitDepths(quantization, header.shDegree, report);
    }
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
    switch (header.profile) {
      case 'capture':
        if (windows.isEmpty ||
            windows.any(
              (FourdgsWindow window) =>
                  !window.lo.isFinite || !window.hi.isFinite,
            )) {
          report.error(
            'the capture profile requires finite validity windows for every gaussian',
          );
        }
        if (index.length <= 1) {
          report.error(
            'the capture profile requires a Chunk Index with more than one entry',
          );
        }
        if (walk.count(opStatistics) == 0) {
          report.error('the capture profile requires a Statistics record');
        }
      case 'objects':
        if (walk.count(opObjectTable) != 1) {
          report.error(
            'the objects profile requires exactly one Object Table; found '
            '${walk.count(opObjectTable)}',
          );
        }
      case 'keyframed':
        if (!keyframeDelta) {
          report.error(
            'the keyframed profile requires temporal_model "keyframe-delta"',
          );
        }
        if (index.length <= 1) {
          report.error(
            'the keyframed profile requires a Chunk Index with more than one entry',
          );
        }
        if (walk.count(opStatistics) == 0) {
          report.error('the keyframed profile requires a Statistics record');
        }
      case 'relightable':
        report.error(
          'the relightable profile is reserved for a future extension and '
          'must not be emitted by a version-1 writer',
        );
    }
  }
  if (seen.contains(opAudio) && audioSources.isNotEmpty) {
    report.error('legacy Audio and Audio Source records must not be mixed');
  }
  for (final MapEntry<int, int> entry in audioSources.entries) {
    final int? length = audioData[entry.key];
    if (length == null) {
      report.error(
        'Audio Source id ${entry.key} has no matching Audio Data record',
      );
    } else if (entry.value != length) {
      report.error(
        'Audio Source id ${entry.key} declares ${entry.value} bytes; '
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
    // Two bounds, and the second is not implied by the first. A record needs a
    // nine-byte header before it needs content, so an entry whose offset is the
    // end of the file and whose length is zero satisfies "the range fits" while
    // pointing at no byte at all — and reading the opcode there is an
    // out-of-range crash rather than a finding, which is a validator that falls
    // over on exactly the input it exists for.
    if (entry.chunkOffset < 0 ||
        entry.chunkLength < 0 ||
        entry.chunkOffset + recordHeaderBytes > walk.size ||
        entry.chunkOffset + entry.chunkLength > walk.size) {
      report.error('chunk index entry $i points past the end of the file');
      continue;
    }
    // A `keyframe-delta` file indexes both kinds: a Chunk is a keyframe and a
    // Delta Chunk is a difference against one, and an index that could only name
    // the former could not seek the model at all.
    final int at = (await source.read(entry.chunkOffset, 1))[0];
    if (at != opChunk && !(keyframeDelta && at == opDeltaChunk)) {
      report.error('chunk index entry $i does not point at a Chunk record');
    }
  }

  if (footer != null &&
      footerOffset >= 0 &&
      footer.summaryCrc != 0 &&
      footer.summaryStart == 0) {
    report.error(
      'the Footer declares summary_crc ${footer.summaryCrc}, but '
      'summary_start is 0 and there is no summary range to checksum',
    );
  } else if (footer != null && footerOffset >= 0 && footer.summaryCrc != 0) {
    // The summary ends exactly where the framed Footer begins. Deriving this
    // from a fixed Footer size would include appended, forward-compatible
    // Footer fields in the CRC range (§4.2).
    final int tail = footerOffset;
    if (footer.summaryStart > tail) {
      report.error(
        "the Footer's summary starts at ${footer.summaryStart}, after the "
        'summary ends at $tail',
      );
    } else if (await fourdgsCrc32Range(
          source,
          footer.summaryStart,
          tail - footer.summaryStart,
        ) !=
        footer.summaryCrc) {
      report.error(
        'summary CRC mismatch: the index is untrustworthy (a streamed read '
        'still works)',
      );
    }
  }

  if (footer != null && footerOffset >= 0) {
    if (summaryOffsetFrameOffsets.isEmpty) {
      if (footer.summaryOffsetStart != 0) {
        report.error(
          "the Footer declares summary_offset_start "
          '${footer.summaryOffsetStart}, but the file carries no Summary Offset record',
        );
      }
    } else if (footer.summaryOffsetStart != summaryOffsetFrameOffsets.first) {
      report.error(
        "the Footer declares the first Summary Offset at "
        '${footer.summaryOffsetStart}, but framing found it at '
        '${summaryOffsetFrameOffsets.first}',
      );
    }
    if (footer.summaryStart == 0 && summaryFrameOffsets.isNotEmpty) {
      report.error(
        'the Footer declares summary_start 0 (no index), but the framing walk '
        'found ${walk.count(opChunkIndex) + walk.count(opStatistics) + walk.count(opSummaryOffset)} '
        'summary record(s), beginning at '
        '${summaryFrameOffsets.join(", ")}',
      );
    } else if (footer.summaryStart != 0) {
      const Set<int> summaryOpcodes = <int>{
        opChunkIndex,
        opStatistics,
        opSummaryOffset,
      };
      await for (final FourdgsFrame frame in walkFourdgsFrames(source, walk)) {
        final bool inSummary =
            footer.summaryStart <= frame.offset && frame.offset < footerOffset;
        if (inSummary && !summaryOpcodes.contains(frame.opcode)) {
          report.error(
            'the Footer summary range [${footer.summaryStart}, $footerOffset) '
            'contains ${opcodeName(frame.opcode)} at byte ${frame.offset}; only '
            'Chunk Index, Statistics, and Summary Offset records are legal in '
            'the complete summary run',
          );
        }
        if (!inSummary && summaryOpcodes.contains(frame.opcode)) {
          report.error(
            '${opcodeName(frame.opcode)} at byte ${frame.offset} sits outside '
            'the Footer summary range [${footer.summaryStart}, $footerOffset)',
          );
        }
      }
      if (indexFrameOffsets.isEmpty ||
          indexFrameOffsets.first != footer.summaryStart) {
        report.error(
          'the Footer declares the Chunk Index at ${footer.summaryStart}, but '
          'the complete framing walk found Chunk Index records at '
          '${indexFrameOffsets.isEmpty ? "no offsets" : indexFrameOffsets.join(", ")}',
        );
      }
    }

    for (final _SummaryOffsetAt declaration in summaryOffsets) {
      final String? problem = await _summaryOffsetProblem(
        source,
        declaration.value,
        footer.summaryStart,
        footerOffset,
      );
      if (problem != null) {
        report.error(
          'the Summary Offset record at byte ${declaration.offset} $problem',
        );
      }
    }
  }

  if (header != null && footer?.summaryStart == 0) {
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
    // Opening the file the way a seeking client would is itself a check, and it
    // is the same check for both temporal models — the Footer is last, the tail
    // is where the tail should be, and every index entry obeys §5.8. The
    // keyframe-delta branch used to skip it and composed its chains straight
    // from the framing, which meant a delta file with a record after its Footer,
    // an unknown `chunk_kind` or a zero-width nonempty entry was reported valid
    // while every reader in the repository refused it.
    final FourdgsIndexedScene? scene;
    try {
      scene = await openFourdgsIndexed(
        source,
        framedFooterOffset: footerOffset >= 0 ? footerOffset : null,
        framedFooterLength: footerLength >= 0 ? footerLength : null,
      );
    } on FourdgsException catch (error) {
      report.refused(
        'a seeking reader cannot open this file: ',
        error,
        walk: walk,
      );
      // A file that will not open will not decode either, and the second error
      // would say the same thing about the same byte.
      return FourdgsValidation(report.findings);
    }
    if (scene.index.length != index.length) {
      report.error(
        'the complete framing walk found ${index.length} parsed Chunk Index '
        'records, but the Footer-addressed summary exposes ${scene.index.length}',
      );
    }
    // The record families the framing walk steps over and a public decoder
    // refuses: a truncated ObjectTrack or a malformed CoordinateFrame is a file
    // `readFourdgsObjects` and `readFourdgsProvenance` decline, so a validator
    // that only framed them would call it valid.
    await _checkAuxiliaryRecords(source, walk, report);
    if (keyframeDelta) {
      await _checkKeyframeDelta(
        source,
        walk,
        scene,
        report,
        windows: windows,
        indexRecordOffsets: indexRecordOffsets,
        requireObjectId: header?.profile == 'objects',
      );
    } else {
      await _checkGaussianBirth(
        source,
        walk,
        scene,
        report,
        quantization: quantization,
        windows: windows,
        cutoff: header?.cutoff ?? fourdgsDefaultCutoff,
        requireObjectId: header?.profile == 'objects',
      );
    }
  }

  return FourdgsValidation(report.findings);
}

/// Validates the range one Summary Offset advertises without materializing it.
///
/// The declaration exists so a reader can fetch only this group, so its range
/// must itself be sufficient proof: nonempty, wholly inside the framed
/// summary, beginning on a record boundary, and containing only the opcode it
/// names. Walking fixed headers keeps the check bounded by one record header.
Future<String?> _summaryOffsetProblem(
  FourdgsReadable source,
  FourdgsSummaryOffset declaration,
  int summaryStart,
  int footerOffset,
) async {
  final int start = declaration.groupStart;
  final int length = declaration.groupLength;
  if (summaryStart == 0) {
    return 'declares a group while the Footer declares no summary';
  }
  if (start == 0) {
    return 'declares group_start 0; expected a framed group inside the summary';
  }
  if (length == 0) {
    return 'declares group_length 0; expected at least one referenced record';
  }
  if (start < summaryStart ||
      start >= footerOffset ||
      length > footerOffset - start) {
    return 'declares group range [$start, ${start + length}), outside the '
        'Footer summary range [$summaryStart, $footerOffset)';
  }

  final int end = start + length;
  int at = start;
  bool referenced = false;
  const Set<int> legalSummaryOpcodes = <int>{
    opChunkIndex,
    opStatistics,
    opSummaryOffset,
  };
  while (at < end) {
    if (end - at < recordHeaderBytes) {
      return 'ends with ${end - at} bytes at byte $at, too few for a record '
          'header';
    }
    final FourdgsCursor framing = FourdgsCursor(
      await source.read(at, recordHeaderBytes),
    );
    final int opcode = framing.u8();
    final int contentLength = framing.u64();
    final int total = recordHeaderBytes + contentLength;
    if (total > end - at) {
      return 'ends at $end inside the ${opcodeName(opcode)} record at byte '
          '$at, whose framing ends at ${at + total}';
    }
    if (!legalSummaryOpcodes.contains(opcode)) {
      return 'includes ${opcodeName(opcode)} at byte $at, which is not a '
          'summary record';
    }
    referenced |= opcode == declaration.groupOpcode;
    at += total;
  }
  if (!referenced) {
    return 'does not reference any ${opcodeName(declaration.groupOpcode)} record';
  }
  return null;
}

/// The object layer and the provenance family, parsed rather than framed.
///
/// `openFourdgsIndexed` frames these and remembers their byte ranges; their
/// bodies are parsed only when a caller asks for them, which is what makes
/// opening a scene with a thousand-sample rig trajectory cost nothing. A
/// validator is that caller. Without this a file carrying a truncated
/// ObjectTrack, two Object Tables, or a CoordinateFrame that will not parse gets
/// a clean report from the tool and a refusal from the API — the two disagreeing
/// about the same bytes.
Future<void> _checkAuxiliaryRecords(
  FourdgsReadable source,
  FourdgsWalk walk,
  _Report report,
) async {
  await _checkProvenanceRecords(source, walk, report);
  await _checkObjectRecords(source, walk, report);
  // Camera is singular in the indexed scene model, but validation walks every
  // framed record so a malformed later Camera cannot hide behind the first.
  await for (final FourdgsFrame frame in walkFourdgsFrames(source, walk)) {
    if (frame.opcode != opCamera || frame.offset + frame.total > walk.size) {
      continue;
    }
    try {
      FourdgsCamera.parse(
        await _bytesOf(source, frame),
        fileOffset: frame.offset + recordHeaderBytes,
      );
    } on FourdgsException catch (error) {
      report.error(
        'the Camera record at byte ${frame.offset} does not decode: ${_say(error)}',
      );
    }
  }
  // Parse and release one Metadata record at a time. Returning the public
  // reader's aggregate list here would make peak memory the sum of every legal
  // record in the family rather than the per-record bound.
  await for (final FourdgsFrame frame in walkFourdgsFrames(source, walk)) {
    if (frame.opcode != opMetadata || frame.offset + frame.total > walk.size) {
      continue;
    }
    try {
      FourdgsMetadata.parse(await _bytesOf(source, frame));
    } on FourdgsException catch (error) {
      report.error(
        'the Metadata record at byte ${frame.offset} does not decode: ${_say(error)}',
      );
    }
  }
}

/// Parse the object layer without retaining every track's sample arrays.
///
/// The public reader returns those arrays because a consumer needs them. A
/// validator needs only structural validity, one-table cardinality, and the
/// object ids that already have a nonempty track; each decoded record can be
/// released before the next range read.
Future<void> _checkObjectRecords(
  FourdgsReadable source,
  FourdgsWalk walk,
  _Report report,
) async {
  bool hasTable = false;
  final trackedIds = <int>{};
  await for (final FourdgsFrame frame in walkFourdgsFrames(source, walk)) {
    if (frame.offset + frame.total > walk.size) continue;
    try {
      if (frame.opcode == opObjectTable) {
        if (hasTable) {
          throw const FourdgsMalformedFile(
            'the file carries a second Object Table; a scene has one '
            '(section 5.15.6)',
          );
        }
        FourdgsObjectTable.parse(await _bytesOf(source, frame));
        hasTable = true;
      } else if (frame.opcode == opObjectTrack) {
        final track = FourdgsObjectTrack.parse(await _bytesOf(source, frame));
        if (track.sampleCount > 0 && !trackedIds.add(track.objectId)) {
          throw FourdgsMalformedFile(
            'two ObjectTrack records move object ${track.objectId}; a '
            'gaussian has one object and cannot be transported by two poses '
            '(section 5.15.7)',
          );
        }
      }
    } on FourdgsException catch (error) {
      report.error(
        'the ${opcodeName(frame.opcode)} record at byte ${frame.offset} does '
        'not decode: ${_say(error)}',
      );
    }
  }
}

/// Parse provenance a record at a time instead of materializing the family.
///
/// Trajectories are the important case: each record has a bounded decoded
/// allocation, but retaining every sample array until the final cross-record
/// checks makes peak memory the size of the capture. Only names survive the
/// first pass; a second pass checks references after all targets are known.
Future<void> _checkProvenanceRecords(
  FourdgsReadable source,
  FourdgsWalk walk,
  _Report report,
) async {
  Never duplicate(String kind, String name, String section) =>
      throw FourdgsMalformedFile(
        "two $kind records are named '$name'; these records are referred to "
        'by name and nothing else (section $section)',
      );

  await for (final FourdgsFrame frame in walkFourdgsFrames(source, walk)) {
    if (frame.offset + frame.total > walk.size) continue;
    try {
      switch (frame.opcode) {
        case opCoordinateFrame:
          final value = FourdgsCoordinateFrame.parse(
            await _bytesOf(source, frame),
          );
          if (await _provenanceNameExists(
            source,
            walk,
            opCoordinateFrame,
            value.name,
            beforeOffset: frame.offset,
          )) {
            duplicate('CoordinateFrame', value.name, '5.15.2');
          }
          final double? registered = lengthUnitMetres[value.lengthUnit];
          if (value.handedness != 0 &&
              value.handedness != 1 &&
              value.handedness != 2) {
            report.warn(
              'Coordinate Frame "${value.name}" handedness '
              '${value.handedness} is not in the registry',
            );
          }
          if (value.lengthUnit != 0 && registered == null) {
            report.warn(
              'Coordinate Frame "${value.name}" length_unit '
              '${value.lengthUnit} is not in the registry',
            );
          }
          if (registered != null &&
              value.metresPerUnit > 0.0 &&
              value.metresPerUnit != registered) {
            report.error(
              'Coordinate Frame "${value.name}" declares length_unit '
              '${value.lengthUnit}, which means $registered metres per unit, '
              'but metres_per_unit is ${value.metresPerUnit}; both fields must '
              'agree',
            );
          }
        case opSensorCalibration:
          final value = FourdgsSensorCalibration.parse(
            await _bytesOf(source, frame),
          );
          if (await _provenanceNameExists(
            source,
            walk,
            opSensorCalibration,
            value.name,
            beforeOffset: frame.offset,
          )) {
            duplicate('SensorCalibration', value.name, '5.15.3');
          }
          if (value.poseReference != poseToScene &&
              value.poseReference != poseToRig) {
            throw FourdgsMalformedFile(
              "sensor '${value.name}' declares pose_reference "
              '${value.poseReference}; the registry defines 0 (scene) and 1 '
              '(rig)',
            );
          }
          if (value.poseReference == poseToRig &&
              !await _provenanceNameExists(
                source,
                walk,
                opRigTrajectory,
                value.rigName,
              )) {
            throw FourdgsMalformedFile(
              "sensor '${value.name}' is posed against rig "
              "'${value.rigName}', which this file does not carry (section "
              '5.15.3)',
            );
          }
        case opRigTrajectory:
          final value = FourdgsRigTrajectory.parse(
            await _bytesOf(source, frame),
          );
          // Zero-sample trajectories are read as absent, including for name
          // uniqueness and later rig references.
          if (value.sampleCount > 0 &&
              await _provenanceNameExists(
                source,
                walk,
                opRigTrajectory,
                value.name,
                beforeOffset: frame.offset,
              )) {
            duplicate('RigTrajectory', value.name, '5.15.4');
          }
          if (value.sampleCount > 0 &&
              value.interpolation != trajectoryLinear &&
              value.interpolation != trajectoryStep) {
            report.warn(
              "trajectory '${value.name}' names interpolation "
              '${value.interpolation}, which is not in the registry',
            );
          }
        case opGeodeticAnchor:
          final value = FourdgsGeodeticAnchor.parse(
            await _bytesOf(source, frame),
          );
          if (await _provenanceNameExists(
            source,
            walk,
            opGeodeticAnchor,
            value.frameName,
            beforeOffset: frame.offset,
          )) {
            duplicate('GeodeticAnchor', value.frameName, '5.15.5');
          }
          if (!await _provenanceNameExists(
            source,
            walk,
            opCoordinateFrame,
            value.frameName,
          )) {
            throw FourdgsMalformedFile(
              "a GeodeticAnchor anchors frame '${value.frameName}', which this "
              'file does not define; an anchor for a frame nobody declared is a '
              'latitude attached to nothing (section 5.15.5)',
            );
          }
      }
    } on FourdgsException catch (error) {
      report.error(
        'the ${opcodeName(frame.opcode)} record at byte ${frame.offset} does '
        'not decode: ${_say(error)}',
      );
    }
  }
}

/// Whether an earlier (or any) record of one provenance class carries [name].
///
/// Replaying ranges trades time for the invariant validators need most: memory
/// is one independently bounded record, not the aggregate number or length of
/// names in the file. Malformed replay records are ignored here and diagnosed
/// once when the outer pass reaches their own byte offset.
Future<bool> _provenanceNameExists(
  FourdgsReadable source,
  FourdgsWalk walk,
  int wantedOpcode,
  String name, {
  int? beforeOffset,
}) async {
  await for (final FourdgsFrame frame in walkFourdgsFrames(source, walk)) {
    if (beforeOffset != null && frame.offset >= beforeOffset) break;
    if (frame.opcode != wantedOpcode ||
        frame.offset + frame.total > walk.size) {
      continue;
    }
    try {
      final Uint8List bytes = await _bytesOf(source, frame);
      switch (wantedOpcode) {
        case opCoordinateFrame:
          if (FourdgsCoordinateFrame.parse(bytes).name == name) return true;
        case opSensorCalibration:
          if (FourdgsSensorCalibration.parse(bytes).name == name) return true;
        case opRigTrajectory:
          final value = FourdgsRigTrajectory.parse(bytes);
          if (value.sampleCount > 0 && value.name == name) return true;
        case opGeodeticAnchor:
          if (FourdgsGeodeticAnchor.parse(bytes).frameName == name) return true;
      }
    } on FourdgsException {
      continue;
    }
  }
  return false;
}

/// Validate the optional per-band SH-depth declaration against Header degree.
void _checkShBitDepths(
  FourdgsQuantization quantization,
  int shDegree,
  _Report report,
) {
  if (quantization.shBitDepthsMalformed) {
    report.error(
      'Quantization carries a malformed SH bit-depth declaration; the count '
      'must fit the append and every depth must be in 3..8 (§6.5)',
    );
    return;
  }
  final List<int> depths = quantization.shBitDepths;
  if (depths.isEmpty || shDegree <= 0) return;
  if (depths.length != shDegree) {
    report.error(
      'Quantization declares ${depths.length} SH bit depths; the Header '
      'declares degree $shDegree, and there is one band per degree (§6.5)',
    );
  }
  final int compared = depths.length < shDegree ? depths.length : shDegree;
  int coarsest = 0;
  for (int i = 0; i < compared; i++) {
    final int band = i + 1;
    final int step = 1 << (8 - depths[i]);
    final int bound = step ~/ 2;
    if (step > coarsest) coarsest = step;
    final String key = 'sh_band$band';
    final String? declared = quantization.bounds[key];
    if (declared == null) {
      report.warn(
        'Quantization declares ${depths[i]} bits for SH band $band but no '
        '`$key` bound (§5.3)',
      );
    } else if (declared != '$bound') {
      report.warn(
        'Quantization declares `$key` as $declared; ${depths[i]} bits gives a '
        'bound of $bound (§6.5)',
      );
    }
  }
  if (compared > 0 && quantization.stepSh != coarsest) {
    report.warn(
      'Quantization step_sh is ${quantization.stepSh}; the coarsest declared '
      'band has a pitch of $coarsest, which is what a consumer that reads only '
      'step_sh has to be given (§6.5)',
    );
  }
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
void _noteUnread(_Report report, FourdgsFrame frame) {
  final String hex =
      '0x${frame.opcode.toRadixString(16).padLeft(2, '0').toUpperCase()}';
  if (isPrivateOpcode(frame.opcode)) {
    report.note(
      'private record $hex (${frame.length} bytes) — skipped, as required',
    );
  } else if (isSpecifiedOpcode(frame.opcode)) {
    // A record this pass has nothing to say about. The object layer and
    // provenance are parsed below, from the ranges the indexed opener framed;
    // a Camera, a Metadata record or an Attachment is framed and stepped over.
  } else if (isProvenanceOpcode(frame.opcode)) {
    report.error(
      'reserved provenance opcode $hex appears at byte ${frame.offset}; '
      'version 1 writers MUST NOT emit 0x26-0x2F (section 5.15.6)',
    );
  } else {
    report.note('unknown record $hex — skipped, as required');
  }
}

Future<void> _checkFramedTiling(
  FourdgsReadable source,
  FourdgsWalk walk,
  double durationSec,
  _Report report,
) async {
  // Physical records need not be in t0 order (§11.1), so a one-pass adjacent
  // comparison is insufficient. Select the next interval in sorted order with
  // bounded replay: each pass retains two fixed-size interval heads, never a
  // list proportional to the number of chunks.
  _StateInterval? previous;
  while (true) {
    _StateInterval? next;
    await for (final FourdgsFrame frame in walkFourdgsFrames(source, walk)) {
      if ((frame.opcode != opChunk && frame.opcode != opDeltaChunk) ||
          frame.offset + frame.total > walk.size) {
        continue;
      }
      final _StateInterval interval;
      try {
        interval = await _framedStateInterval(source, frame);
      } on FourdgsException {
        // The framing pass already reported this record's parse error.
        continue;
      }
      final _StateInterval? selected = previous;
      if (selected != null &&
          (interval.t0 < selected.t0 ||
              (interval.t0 == selected.t0 &&
                  interval.offset <= selected.offset))) {
        continue;
      }
      final _StateInterval? candidate = next;
      if (candidate == null ||
          interval.t0 < candidate.t0 ||
          (interval.t0 == candidate.t0 && interval.offset < candidate.offset)) {
        next = interval;
      }
    }
    if (next == null) break;
    final _StateInterval current = next;
    if (previous == null) {
      if (current.t0 != 0.0) {
        report.error(
          'the state chunks start at ${current.t0} in the record at byte '
          '${current.offset}; the timeline must start at 0',
        );
      }
    } else if (previous.t1 != current.t0) {
      final String what = current.t0 < previous.t1 ? 'overlap' : 'leave a gap';
      report.error(
        'state chunks $what: [${previous.t0}, ${previous.t1}) at byte '
        '${previous.offset} is followed by [${current.t0}, ${current.t1}) at '
        'byte ${current.offset}',
      );
    }
    previous = current;
  }
  if (previous == null) {
    report.error('a keyframe-delta file contains no state chunks');
    return;
  }
  if (previous.t1 != durationSec) {
    report.error(
      'the state chunks end at ${previous.t1} in the record at byte '
      '${previous.offset}; '
      'the Header duration_sec is $durationSec',
    );
  }
}

Future<_StateInterval> _framedStateInterval(
  FourdgsReadable source,
  FourdgsFrame frame,
) async {
  if (frame.opcode == opChunk) {
    final parsed = parseChunkInterval(
      await _bytesOf(source, frame, most: chunkFixedHeadBytes),
      fileOffset: frame.offset + recordHeaderBytes,
    );
    return (t0: parsed.t0, t1: parsed.t1, offset: frame.offset);
  }
  final FourdgsCursor cursor = FourdgsCursor(
    await _bytesOf(source, frame, most: 16),
  );
  final double t0 = cursor.f64();
  final double t1 = cursor.f64();
  refuseUnusableInterval(
    t0,
    t1,
    frame.offset + recordHeaderBytes,
    'Delta Chunk',
  );
  return (t0: t0, t1: t1, offset: frame.offset);
}

/// Validate a legacy Audio descriptor without fetching its payload.
///
/// The codec is a length-prefixed string, not a 512-byte field. Read its length
/// first and stream the bounded UTF-8 bytes so a legal long name is not mistaken
/// for a truncated descriptor.
Future<void> _checkLegacyAudioHead(
  FourdgsReadable source,
  FourdgsFrame frame,
) async {
  int at = await _boundedString(source, frame, 0, 'legacy Audio', 'codec');
  const int fixed = 8 + 8; // start_sec, data_length
  if (at + fixed > maxFrontMatterBytes) {
    throw FourdgsMalformedFile(
      'the legacy Audio descriptor reaches ${fourdgsCommas(at + fixed)} bytes, '
      'past the ${fourdgsCommas(maxFrontMatterBytes)}-byte front-matter ceiling',
    );
  }
  if (at + fixed > frame.length) {
    throw FourdgsTruncatedFile(
      'the legacy Audio descriptor needs $fixed bytes at content offset $at, '
      '${frame.length - at} remain',
    );
  }
  final FourdgsCursor cursor = FourdgsCursor(
    await source.read(frame.offset + recordHeaderBytes + at, fixed),
  );
  cursor.f64();
  final int dataLength = cursor.u64();
  at += fixed;
  if (dataLength > frame.length - at) {
    throw FourdgsTruncatedFile(
      'the legacy Audio record declares $dataLength data bytes, but its '
      'content is only ${frame.length} bytes',
    );
  }
}

/// Validate an Attachment's two strings and payload length without fetching
/// the payload. The two strings are streamed through the UTF-8 decoder, so a
/// large but bounded name does not become a second whole-record allocation.
Future<void> _checkAttachmentHead(
  FourdgsReadable source,
  FourdgsFrame frame,
) async {
  int at = 0;
  at = await _attachmentString(source, frame, at, 'name');
  at = await _attachmentString(source, frame, at, 'media type');
  if (at + 8 > maxFrontMatterBytes) {
    throw FourdgsMalformedFile(
      'the Attachment header reaches ${fourdgsCommas(at + 8)} bytes, past the '
      '${fourdgsCommas(maxFrontMatterBytes)}-byte front-matter ceiling',
    );
  }
  if (at + 8 > frame.length) {
    throw FourdgsTruncatedFile(
      'the Attachment payload length needs 8 bytes at content offset $at, '
      '${frame.length - at} remain',
    );
  }
  final int dataLength =
      FourdgsCursor(
        await source.read(frame.offset + recordHeaderBytes + at, 8),
      ).u64();
  at += 8;
  if (dataLength > frame.length - at) {
    throw FourdgsTruncatedFile(
      'the Attachment declares $dataLength payload bytes at content offset '
      '$at, ${frame.length - at} remain',
    );
  }
}

Future<int> _attachmentString(
  FourdgsReadable source,
  FourdgsFrame frame,
  int at,
  String field,
) => _boundedString(source, frame, at, 'Attachment', field);

Future<int> _boundedString(
  FourdgsReadable source,
  FourdgsFrame frame,
  int at,
  String record,
  String field,
) async {
  if (at + 4 > frame.length) {
    throw FourdgsTruncatedFile(
      'the $record $field length needs 4 bytes at content offset $at, '
      '${frame.length - at} remain',
    );
  }
  final Uint8List lengthBytes = await source.read(
    frame.offset + recordHeaderBytes + at,
    4,
  );
  final int length = ByteData.sublistView(
    lengthBytes,
  ).getUint32(0, Endian.little);
  final int bytesAt = at + 4;
  if (length > frame.length - bytesAt) {
    throw FourdgsTruncatedFile(
      'the $record $field declares $length bytes at content offset '
      '$bytesAt, ${frame.length - bytesAt} remain',
    );
  }
  if (bytesAt + length > maxFrontMatterBytes) {
    throw FourdgsMalformedFile(
      'the $record header reaches ${fourdgsCommas(bytesAt + length)} bytes, '
      'past the ${fourdgsCommas(maxFrontMatterBytes)}-byte front-matter ceiling',
    );
  }
  final ByteConversionSink decoder = const Utf8Decoder().startChunkedConversion(
    const _DiscardStrings(),
  );
  int consumed = 0;
  try {
    while (consumed < length) {
      final int remaining = length - consumed;
      final int take =
          remaining < fourdgsCrcBlockBytes ? remaining : fourdgsCrcBlockBytes;
      decoder.add(
        await source.read(
          frame.offset + recordHeaderBytes + bytesAt + consumed,
          take,
        ),
      );
      consumed += take;
    }
    decoder.close();
  } on FormatException catch (error) {
    throw FourdgsMalformedFile(
      'the $record $field at content offset $bytesAt is not valid UTF-8: '
      '${error.message}',
    );
  }
  return bytesAt + length;
}

class _DiscardStrings implements Sink<String> {
  const _DiscardStrings();

  @override
  void add(String data) {}

  @override
  void close() {}
}

/// How much of an Audio Data record's content [_audioDataHead] needs: the `u32`
/// source id and the `u64` length in front of the payload.
const int audioDataHeadBytes = 12;

/// An Audio Data record's id and declared payload length, without its payload.
({int sourceId, int length}) _audioDataHead(
  Uint8List head,
  FourdgsFrame frame,
) {
  final FourdgsCursor cursor = FourdgsCursor(head);
  final int sourceId = cursor.u32();
  final int length = cursor.u64();
  // What `blob()` would have refused when it went to take the payload, raised
  // here instead so that the payload is never transferred to find it out.
  if (length > frame.length - audioDataHeadBytes) {
    throw FourdgsTruncatedFile(
      'need $length bytes at offset $audioDataHeadBytes, '
      '${frame.length - audioDataHeadBytes} remain',
    );
  }
  return (sourceId: sourceId, length: length);
}

/// The content of [frame], or the first [most] bytes of it.
///
/// A record's declared length comes out of the file, so a corrupt or hostile one
/// can name a length no machine has the memory for. The records this pass parses
/// whole are front matter and are held to the same ceiling the indexed opener
/// applies to them; the two records that can legitimately be enormous — a Chunk
/// and an Audio Data payload — are read as fixed heads instead.
Future<Uint8List> _bytesOf(
  FourdgsReadable source,
  FourdgsFrame frame, {
  int? most,
}) {
  final int want = most == null || most > frame.length ? frame.length : most;
  if (want > maxFrontMatterBytes) {
    throw FourdgsMalformedFile(
      'the ${opcodeName(frame.opcode)} record at byte ${frame.offset} declares '
      '${fourdgsCommas(frame.length)} bytes, past the '
      '${fourdgsCommas(maxFrontMatterBytes)}-byte ceiling this reader will hold '
      'for one record',
    );
  }
  return source.read(frame.offset + recordHeaderBytes, want);
}

/// The checks only a reader can perform: decode the file it just opened.
///
/// There is no substitute for decoding: the framing walk steps over a chunk by
/// its declared length, so an unimplemented stream codec and an out-of-range
/// window index are both invisible to everything above — and so is a
/// spherical-harmonic band that will not decode, which is a whole record class a
/// framing walk has nothing to say about.
Future<void> _checkGaussianBirth(
  FourdgsReadable source,
  FourdgsWalk walk,
  FourdgsIndexedScene scene,
  _Report report, {
  required FourdgsQuantization? quantization,
  required List<FourdgsWindow> windows,
  required double cutoff,
  required bool requireObjectId,
}) async {
  final Map<int, int> firstIndexAt = <int, int>{};
  for (int i = 0; i < scene.index.length; i++) {
    final int offset = scene.index[i].chunkOffset;
    final int? previous = firstIndexAt[offset];
    if (previous != null) {
      report.error(
        'chunk index entries $previous and $i both name the gaussian-birth '
        'Chunk at byte $offset; the format defines one entry per chunk',
      );
    } else {
      firstIndexAt[offset] = i;
    }
  }
  final Set<int> indexedOffsets = firstIndexAt.keys.toSet();
  final Map<int, List<FourdgsBandRange>> framedBands =
      <int, List<FourdgsBandRange>>{};
  final Map<int, int> framedPopulations = <int, int>{};
  if (await _scanFramedChunks(
    source,
    walk,
    report,
    quantization: quantization,
    windows: windows,
    cutoff: cutoff,
    degree: scene.header.shDegree,
    indexedOffsets: indexedOffsets,
    framedBands: framedBands,
    framedPopulations: framedPopulations,
    requireObjectId: requireObjectId,
  )) {
    return;
  }
  if (scene.index.isEmpty) return;

  final Map<int, FourdgsFrame> framedChunks = <int, FourdgsFrame>{};
  await for (final FourdgsFrame frame in walkFourdgsFrames(source, walk)) {
    if (frame.opcode == opChunk &&
        frame.offset + frame.total <= walk.size &&
        indexedOffsets.contains(frame.offset)) {
      framedChunks[frame.offset] = frame;
    }
  }
  for (int i = 0; i < scene.index.length; i++) {
    final FourdgsChunkIndexEntry entry = scene.index[i];
    final FourdgsFrame? framed = framedChunks[entry.chunkOffset];
    if (framed == null) {
      report.error(
        'chunk index entry $i names byte ${entry.chunkOffset}, where the '
        'framing walk found no complete Chunk record',
      );
      continue;
    }
    if (entry.chunkLength != framed.total) {
      report.error(
        'chunk index entry $i declares length ${entry.chunkLength} for the '
        'Chunk at byte ${entry.chunkOffset}; its framing declares '
        '${framed.total}',
      );
      continue;
    }
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
    // The count the index promised, which `readFourdgsChunk` has just checked
    // the chunk's own header against.
    if (await _checkBands(
      source,
      entry,
      i,
      report,
      count: entry.gaussianCount,
      resourceSize: walk.size,
      framedBands: framedBands[entry.chunkOffset],
    )) {
      return;
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
Future<bool> _scanFramedChunks(
  FourdgsReadable source,
  FourdgsWalk walk,
  _Report report, {
  required FourdgsQuantization? quantization,
  required List<FourdgsWindow> windows,
  required double cutoff,
  required int degree,
  required Set<int> indexedOffsets,
  required Map<int, List<FourdgsBandRange>> framedBands,
  required Map<int, int> framedPopulations,
  required bool requireObjectId,
}) async {
  if (quantization == null) return false; // already reported as missing
  int count = 0;
  int chunkOffset = -1;
  List<FourdgsBandRange> chunkBands = <FourdgsBandRange>[];

  bool finishChunk() {
    if (chunkOffset < 0) return false;
    final bool failed = _checkStateBandCoverage(
      chunkOffset,
      chunkBands,
      count,
      degree,
      report,
    );
    // The index is bounded independently. Retain band ranges only for offsets
    // it names; an indexless stream therefore drops every completed chunk's
    // bookkeeping before the next chunk is decoded.
    if (indexedOffsets.isNotEmpty) {
      if (!indexedOffsets.contains(chunkOffset)) {
        report.error(
          'the Chunk record at byte $chunkOffset is a complete '
          'gaussian-birth chunk the Chunk Index does not name',
        );
      } else {
        framedBands[chunkOffset] = List<FourdgsBandRange>.of(chunkBands);
        framedPopulations[chunkOffset] = count;
      }
    }
    return failed;
  }

  await for (final FourdgsFrame frame in walkFourdgsFrames(source, walk)) {
    if (frame.opcode != opChunk && frame.opcode != opShBandStream) continue;
    if (frame.offset + frame.total > walk.size) continue; // the cut record
    int? framedBand;
    try {
      final Uint8List content = _content(
        await source.read(frame.offset, frame.total),
        frame.opcode,
      );
      if (frame.opcode == opChunk) {
        if (finishChunk()) return true;
        final FourdgsChunkBody body = parseChunk(content);
        count = body.header.count;
        final FourdgsCursor streamCursor = FourdgsCursor(body.streams);
        bool hasObjectId = false;
        while (streamCursor.remaining > 0) {
          final FourdgsStreamHeader stream = readStreamHeader(streamCursor);
          if (stream.attributeId == attrGaussianId) {
            throw FourdgsMalformedFile(
              'gaussian-birth Chunk at byte ${frame.offset} carries a '
              'gaussian_id stream; attribute 13 is only legal under '
              'keyframe-delta',
            );
          }
          if (stream.attributeId == attrObjectId) hasObjectId = true;
          skipStreamPayload(streamCursor, stream);
        }
        if (requireObjectId && count > 0 && !hasObjectId) {
          throw FourdgsMalformedFile(
            'the objects profile requires object_id in every non-empty Chunk; '
            'the Chunk at byte ${frame.offset} declares $count gaussians but '
            'carries no attribute 14 stream',
          );
        }
        chunkOffset = frame.offset;
        chunkBands = <FourdgsBandRange>[];
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
      } else {
        // Bands belong to the chunk that precedes them; that adjacency is the
        // only thing that says which chunk's gaussians they colour.
        if (chunkOffset < 0) {
          throw FourdgsMalformedFile(
            'the ShBandStream record at byte ${frame.offset} precedes every '
            'Chunk and has no gaussian population to which it can belong',
          );
        }
        if (content.isEmpty) {
          throw const FourdgsTruncatedFile(
            'a ShBandStream record has no band header',
          );
        }
        framedBand = content[0];
        decodeShBandRecord(
          content,
          expectedBand: framedBand,
          expectedCount: count,
        );
        chunkBands.add(
          FourdgsBandRange(
            band: framedBand,
            offset: frame.offset,
            length: frame.total,
          ),
        );
      }
    } on FourdgsException catch (error) {
      final String record =
          frame.opcode == opShBandStream
              ? 'ShBandStream record for band ${framedBand ?? "?"}'
              : '${opcodeName(frame.opcode)} record';
      report.refused(
        'the $record at byte '
        '${fourdgsCommas(frame.offset)} does not decode: ',
        error,
        site: FourdgsRefusalSite(
          frame.offset,
          'the ${opcodeName(frame.opcode)} record',
        ),
      );
      return true;
    }
  }
  return finishChunk();
}

bool _checkStateBandCoverage(
  int offset,
  List<FourdgsBandRange> bands,
  int population,
  int degree,
  _Report report,
) {
  final List<int> actual = <int>[for (final band in bands) band.band]..sort();
  final List<int> expected =
      population == 0 ? <int>[] : <int>[for (int b = 1; b <= degree; b++) b];
  if (actual.length == expected.length &&
      actual.asMap().entries.every(
        (MapEntry<int, int> value) => value.value == expected[value.key],
      )) {
    return false;
  }
  report.error(
    'the state chunk at byte $offset carries SH bands $actual for $population '
    'gaussians; the Header declares degree $degree and requires $expected',
  );
  return true;
}

/// The same, for the temporal model whose chunks are keyframes and differences.
///
/// Composition follows the complete framing walk once. The only two references
/// the model permits are the current GOP keyframe and the immediately previous
/// state, so retaining those two states validates either delta mode in linear
/// time and bounded memory. It also reaches state chunks an index omitted and
/// works unchanged when the file has no index at all.
///
/// Three things the indexed reader checks that composing alone does not, and
/// that a file therefore used to pass validation without: the population the
/// index declares against the population the chunks compose to (§5.8), the
/// spherical-harmonic bands the entry names, and the `window_index` every
/// composed gaussian carries. The last is the one that reads as valid most
/// convincingly: composition is arithmetic on bins and never looks a window up,
/// so a file naming a window it does not carry composes without complaint and
/// is refused the moment anything reconstructs it.
Future<void> _checkKeyframeDelta(
  FourdgsReadable source,
  FourdgsWalk walk,
  FourdgsIndexedScene scene,
  _Report report, {
  required List<FourdgsWindow> windows,
  required List<int> indexRecordOffsets,
  required bool requireObjectId,
}) async {
  final List<FourdgsChunkIndexEntry> index = scene.index;
  if (index.isNotEmpty) {
    try {
      checkTiling(index, durationSec: scene.header.durationSec);
    } on FourdgsException catch (error) {
      report.error('the state chunks do not tile the timeline: ${_say(error)}');
      return;
    }
  }

  // One forward pass is enough for both temporal modes: a delta may reference
  // only the current GOP keyframe or the immediately previous state. Retaining
  // those two states keeps memory bounded and avoids recomposing a growing
  // chain from its keyframe once for every index entry.
  final Map<int, ({FourdgsChunkIndexEntry entry, int index})> indexedAt =
      <int, ({FourdgsChunkIndexEntry entry, int index})>{};
  for (int i = 0; i < index.length; i++) {
    final previous = indexedAt[index[i].chunkOffset];
    if (previous != null) {
      report.error(
        'chunk index entries ${previous.index} and $i both name the state '
        'chunk at byte ${index[i].chunkOffset}',
      );
    } else {
      indexedAt[index[i].chunkOffset] = (entry: index[i], index: i);
    }
  }

  final Set<int> framedStateOffsets = <int>{};
  final Map<int, int> bandPopulationAt = <int, int>{};
  final Map<int, List<FourdgsBandRange>> framedBandsAt =
      <int, List<FourdgsBandRange>>{};
  // A Header count is an untrusted u64, not an allocation bound. The fixed
  // filter makes definitely-new identities constant-space; a hash collision is
  // resolved by replaying the earlier state records with the same two-state
  // working set as this pass. That can cost time on an adversarial file, but it
  // never retains every historical identity.
  final _IdentityFilter identityFilter = _IdentityFilter();
  int distinctIds = 0;
  KeyframeDeltaState? keyframeState;
  KeyframeDeltaState? previousState;
  int keyframeOffset = -1;
  int keyframeLevel = -1;
  int previousOffset = -1;
  int previousDepth = 0;
  int previousLevel = -1;
  int bandPopulation = -1;
  int bandOwnerOffset = -1;
  List<FourdgsBandRange> bandRun = <FourdgsBandRange>[];
  Set<int> bandNumbers = <int>{};

  bool finishBandRun() {
    if (bandOwnerOffset < 0) return false;
    final bool failed = _checkStateBandCoverage(
      bandOwnerOffset,
      bandRun,
      bandPopulation,
      scene.header.shDegree,
      report,
    );
    if (indexedAt.containsKey(bandOwnerOffset)) {
      framedBandsAt[bandOwnerOffset] = List<FourdgsBandRange>.of(bandRun);
      bandPopulationAt[bandOwnerOffset] = bandPopulation;
    }
    bandOwnerOffset = -1;
    bandPopulation = -1;
    bandRun = <FourdgsBandRange>[];
    bandNumbers = <int>{};
    return failed;
  }

  await for (final FourdgsFrame frame in walkFourdgsFrames(source, walk)) {
    if (frame.offset + frame.total > walk.size) continue;
    if (frame.opcode != opChunk &&
        frame.opcode != opDeltaChunk &&
        frame.opcode != opShBandStream) {
      if (finishBandRun()) return;
      continue;
    }
    if (frame.opcode != opShBandStream && finishBandRun()) return;
    int? framedBand;
    try {
      final Uint8List content = _content(
        await source.read(frame.offset, frame.total),
        frame.opcode,
      );
      if (frame.opcode == opShBandStream) {
        if (bandOwnerOffset < 0 || bandPopulation < 0 || content.isEmpty) {
          throw FourdgsMalformedFile(
            'the ShBandStream record at byte ${frame.offset} does not follow '
            'a state chunk whose band population is known',
          );
        }
        framedBand = content[0];
        decodeShBandRecord(
          content,
          expectedBand: framedBand,
          expectedCount: bandPopulation,
        );
        if (bandPopulation == 0 ||
            framedBand < 1 ||
            framedBand > scene.header.shDegree ||
            !bandNumbers.add(framedBand)) {
          throw FourdgsMalformedFile(
            'the state chunk at byte $bandOwnerOffset is followed by SH band '
            '$framedBand more than its declared population and degree permit; '
            'expected each band from 1 through ${scene.header.shDegree} once',
          );
        }
        bandRun.add(
          FourdgsBandRange(
            band: framedBand,
            offset: frame.offset,
            length: frame.total,
          ),
        );
        continue;
      }

      final indexed = indexedAt[frame.offset];
      final FourdgsChunkIndexEntry? entry = indexed?.entry;
      if (entry != null) framedStateOffsets.add(frame.offset);
      final int entryIndex = indexed?.index ?? -1;
      final String where =
          entry == null
              ? 'the unindexed state chunk at byte ${frame.offset}'
              : _indexWhere(entryIndex, index.length, indexRecordOffsets);
      if (entry != null && entry.chunkLength != frame.total) {
        report.error(
          '$where declares length ${entry.chunkLength} for the state chunk at '
          'byte ${frame.offset}; its framing declares ${frame.total}',
        );
      }
      final KeyframeDeltaState state;

      if (frame.opcode == opChunk) {
        final FourdgsChunkBody body = parseChunk(content);
        state = keyframeDeltaStateFromChunk(content, chunkOffset: frame.offset);
        if (requireObjectId &&
            state.count > 0 &&
            !state.hasAttribute(attrObjectId)) {
          throw FourdgsMalformedFile(
            'the objects profile requires object_id in every non-empty Chunk; '
            'the keyframe Chunk at byte ${frame.offset} carries no attribute '
            '14 stream',
          );
        }
        checkKeyframeDeltaMuT(state, body.header.t0, scene.quantization);
        if (index.isEmpty) {
          distinctIds = await _recordIdentityIntroductions(
            source,
            walk,
            state,
            previousState,
            frame.offset,
            identityFilter,
            distinctIds,
            scene.header.gaussianCount,
            'the keyframe',
          );
        }
        keyframeState = state;
        keyframeOffset = frame.offset;
        keyframeLevel = body.header.level;
        previousDepth = 0;
        previousLevel = body.header.level;
        bandPopulation = body.header.count;
        if (entry != null) {
          if (entry.kind != 0 ||
              entry.t0 != body.header.t0 ||
              entry.t1 != body.header.t1 ||
              entry.gaussianCount != body.header.count ||
              entry.deltaMode != 0 ||
              entry.referenceOffset != 0 ||
              entry.keyframeOffset != frame.offset ||
              entry.depth != 0) {
            report.error(
              '$where disagrees with its keyframe Chunk; duplicated interval, '
              'count, kind, keyframe_offset and depth fields must agree',
            );
          }
        }
      } else {
        final FourdgsDeltaChunkBody body = parseDeltaChunk(content);
        final FourdgsDeltaChunkHeader head = body.header;
        if (head.deltaMode != deltaModeKeyframe &&
            head.deltaMode != deltaModeChained) {
          throw FourdgsMalformedFile(
            'the delta chunk at byte ${frame.offset} declares delta_mode '
            '${head.deltaMode}; expected $deltaModeKeyframe (keyframe) or '
            '$deltaModeChained (chained)',
          );
        }
        final KeyframeDeltaState? reference =
            head.deltaMode == deltaModeKeyframe ? keyframeState : previousState;
        final int expectedReference =
            head.deltaMode == deltaModeKeyframe
                ? keyframeOffset
                : previousOffset;
        final int expectedDepth =
            head.deltaMode == deltaModeKeyframe ? 1 : previousDepth + 1;
        final int expectedLevel =
            head.deltaMode == deltaModeKeyframe ? keyframeLevel : previousLevel;
        if (reference == null ||
            head.referenceOffset != expectedReference ||
            head.keyframeOffset != keyframeOffset ||
            head.depth != expectedDepth ||
            head.referenceOffset >= frame.offset) {
          throw FourdgsMalformedFile(
            'the delta chunk at byte ${frame.offset} declares reference_offset '
            '${head.referenceOffset}, keyframe_offset ${head.keyframeOffset}, '
            'and depth ${head.depth}; its ${head.deltaMode == deltaModeKeyframe ? "keyframe" : "chained"} '
            'position requires $expectedReference, $keyframeOffset, and '
            '$expectedDepth',
          );
        }
        if (head.level != expectedLevel) {
          throw FourdgsMalformedFile(
            'the delta chunk at byte ${frame.offset} declares level '
            '${head.level}, but its reference at byte $expectedReference has '
            'level $expectedLevel; a delta preserves its reference level',
          );
        }
        state = applyKeyframeDeltaBody(
          reference,
          body,
          chunkOffset: frame.offset,
        );
        if (index.isEmpty) {
          distinctIds = await _recordIdentityIntroductions(
            source,
            walk,
            state,
            previousState,
            frame.offset,
            identityFilter,
            distinctIds,
            scene.header.gaussianCount,
            'the delta chunk',
          );
        }
        previousDepth = head.depth;
        previousLevel = head.level;
        bandPopulation = head.birthCount;
        if (entry != null) {
          final int operations =
              head.updateCount + head.birthCount + head.deathCount;
          if (entry.kind != 1 ||
              entry.t0 != head.t0 ||
              entry.t1 != head.t1 ||
              entry.deltaMode != head.deltaMode ||
              entry.referenceOffset != head.referenceOffset ||
              entry.keyframeOffset != head.keyframeOffset ||
              entry.depth != head.depth ||
              entry.gaussianCount != operations) {
            report.error(
              '$where disagrees with its Delta Chunk; duplicated interval, '
              'kind, delta_mode, reference_offset, keyframe_offset, depth and '
              'gaussian_count fields must agree (the chunk carries '
              '$operations update, birth, and death operations)',
            );
          }
        }
      }

      if (index.isNotEmpty && entry == null) {
        report.error(
          'the ${opcodeName(frame.opcode)} record at byte ${frame.offset} is a '
          'state chunk the Chunk Index does not name',
        );
      }
      if (entry != null) {
        if (entry.kind == 0 && entry.liveCount != state.count) {
          report.error(
            '$where declares live_count ${entry.liveCount} for a keyframe '
            'whose chunk holds ${state.count} gaussians; expected the two to '
            'agree',
          );
        }
        final int declared = indexEntryPopulation(entry, isKeyframeDelta: true);
        if (state.count != declared) {
          report.error(
            '$where declares $declared live gaussians over [${entry.t0}, '
            '${entry.t1}), but its chain composes to ${state.count}; expected '
            'the index and the chunks to agree',
          );
        }
      }
      state.checkWindows(windows);
      bandOwnerOffset = frame.offset;
      bandRun = <FourdgsBandRange>[];
      bandNumbers = <int>{};
      previousState = state;
      previousOffset = frame.offset;
    } on FourdgsException catch (error) {
      final String record =
          frame.opcode == opShBandStream
              ? 'ShBandStream record for band ${framedBand ?? "?"}'
              : '${opcodeName(frame.opcode)} record';
      report.refused(
        'the $record at byte '
        '${fourdgsCommas(frame.offset)} does not compose: ',
        error,
        site: FourdgsRefusalSite(
          frame.offset,
          'the ${opcodeName(frame.opcode)} record',
        ),
      );
      return;
    }
  }

  if (finishBandRun()) return;

  for (int i = 0; i < index.length; i++) {
    final FourdgsChunkIndexEntry entry = index[i];
    if (!framedStateOffsets.contains(entry.chunkOffset)) {
      report.error(
        '${_indexWhere(i, index.length, indexRecordOffsets)} names byte '
        '${entry.chunkOffset}, where the framing walk found no complete state '
        'chunk',
      );
      continue;
    }
    if (await _checkBands(
      source,
      entry,
      i,
      report,
      count: bandPopulationAt[entry.chunkOffset],
      resourceSize: walk.size,
      framedBands: framedBandsAt[entry.chunkOffset],
    )) {
      return;
    }
  }
  if (index.isNotEmpty) {
    try {
      distinctIds = await _indexedIdentityIntroductions(
        source,
        index,
        scene.header.gaussianCount,
      );
    } on FourdgsException catch (error) {
      report.refused('the indexed identity timeline does not compose: ', error);
      return;
    }
  }
  if (distinctIds != scene.header.gaussianCount) {
    report.error(
      'Header declares ${scene.header.gaussianCount} distinct gaussian ids; '
      'keyframes and births contain $distinctIds',
    );
  }
}

/// Check births and retired-id reuse in timeline order, not record order.
///
/// Keyframe-referenced deltas in one GOP are independently composable and may
/// be stored out of `t0` order. The already-bounded Chunk Index supplies the
/// timeline; one composed state and one previous-state membership index are
/// resident at a time.
Future<int> _indexedIdentityIntroductions(
  FourdgsReadable source,
  List<FourdgsChunkIndexEntry> index,
  int declared,
) async {
  final timeline = List<FourdgsChunkIndexEntry>.of(index)..sort((a, b) {
    final int byStart = a.t0.compareTo(b.t0);
    return byStart != 0 ? byStart : a.t1.compareTo(b.t1);
  });
  final byOffset = keyframeDeltaChainIndex(index);
  final filter = _IdentityFilter();
  KeyframeDeltaState? previous;
  int distinct = 0;
  for (int position = 0; position < timeline.length; position++) {
    final entry = timeline[position];
    final state = await readKeyframeDeltaChain(
      source,
      index,
      entry,
      byOffset: byOffset,
    );
    final _StateIdIndex? previousIds =
        previous == null ? null : _StateIdIndex(previous.ids);
    final List<int> introductions = <int>[];
    final Set<int> collisionCandidates = <int>{};
    for (final int id in state.ids) {
      if (previousIds?.contains(id) ?? false) continue;
      introductions.add(id);
      if (filter.mightContain(id)) collisionCandidates.add(id);
    }
    final int? reused =
        collisionCandidates.isEmpty
            ? null
            : await _identityAppearedEarlierInTimeline(
              source,
              index,
              timeline,
              position,
              collisionCandidates,
              byOffset,
            );
    if (reused != null) {
      final String what = entry.kind == 1 ? 'the delta chunk' : 'the keyframe';
      final String action = entry.kind == 1 ? 'births' : 'reuses';
      throw FourdgsMalformedFile(
        '$what at byte ${entry.chunkOffset} $action retired gaussian id '
        '$reused; an id is never reused after a death',
      );
    }
    for (final int id in introductions) {
      if (distinct >= declared) {
        throw FourdgsMalformedFile(
          'Header declares $declared distinct gaussian ids, but the state '
          'chunk at byte ${entry.chunkOffset} introduces id $id after that '
          'many identities were already seen',
        );
      }
      filter.add(id);
      distinct += 1;
    }
    previous = state;
  }
  return distinct;
}

/// Exact fallback for a fixed-filter collision in an indexed timeline.
Future<int?> _identityAppearedEarlierInTimeline(
  FourdgsReadable source,
  List<FourdgsChunkIndexEntry> index,
  List<FourdgsChunkIndexEntry> timeline,
  int beforePosition,
  Set<int> candidates,
  Map<int, FourdgsChunkIndexEntry> byOffset,
) async {
  KeyframeDeltaState? previous;
  for (int position = 0; position < beforePosition; position++) {
    final state = await readKeyframeDeltaChain(
      source,
      index,
      timeline[position],
      byOffset: byOffset,
    );
    final _StateIdIndex? previousIds =
        previous == null ? null : _StateIdIndex(previous.ids);
    for (final int id in state.ids) {
      if (candidates.contains(id) && !(previousIds?.contains(id) ?? false)) {
        return id;
      }
    }
    previous = state;
  }
  return null;
}

Future<int> _recordIdentityIntroductions(
  FourdgsReadable source,
  FourdgsWalk walk,
  KeyframeDeltaState state,
  KeyframeDeltaState? previous,
  int offset,
  _IdentityFilter filter,
  int distinct,
  int declared,
  String what,
) async {
  final _StateIdIndex? previousIds =
      previous == null ? null : _StateIdIndex(previous.ids);
  final List<int> introductions = <int>[];
  final Set<int> collisionCandidates = <int>{};
  for (final int id in state.ids) {
    if (previousIds?.contains(id) ?? false) continue;
    introductions.add(id);
    if (filter.mightContain(id)) {
      collisionCandidates.add(id);
    }
  }
  final int? reused =
      collisionCandidates.isEmpty
          ? null
          : await _identityAppearedBeforeAny(
            source,
            walk,
            offset,
            collisionCandidates,
          );
  if (reused != null) {
    final String action = what == 'the delta chunk' ? 'births' : 'reuses';
    throw FourdgsMalformedFile(
      '$what at byte $offset $action retired gaussian id $reused; an id is '
      'never reused after a death',
    );
  }
  for (final int id in introductions) {
    if (distinct >= declared) {
      throw FourdgsMalformedFile(
        'Header declares $declared distinct gaussian ids, but $what at byte '
        '$offset introduces id $id after that many identities were already seen',
      );
    }
    filter.add(id);
    distinct += 1;
  }
  return distinct;
}

/// One per-state membership index for the identity-introduction pass.
///
/// A delta commonly retains almost every prior id. Building the hash set once
/// makes the pass linear on ordinary input instead of scanning the prior state
/// once for every retained id (`O(N²)`). The index is released with the call
/// and never accumulates across chunks.
class _StateIdIndex {
  _StateIdIndex(Int32List ids) : _ids = <int>{for (final int id in ids) id};

  final Set<int> _ids;

  bool contains(int id) => _ids.contains(id);
}

/// Exact fallback for a fixed-filter collision.
///
/// Replays only records before [beforeOffset], retaining the GOP keyframe and
/// previous temporal state. Every colliding introduction in one state is
/// checked during the same replay, so an adversarial state cannot trigger one
/// history scan per gaussian. The candidate set is bounded by that state,
/// never by scene history.
Future<int?> _identityAppearedBeforeAny(
  FourdgsReadable source,
  FourdgsWalk walk,
  int beforeOffset,
  Set<int> candidates,
) async {
  KeyframeDeltaState? keyframe;
  KeyframeDeltaState? previous;
  await for (final FourdgsFrame frame in walkFourdgsFrames(source, walk)) {
    if (frame.offset >= beforeOffset) break;
    if (frame.opcode != opChunk && frame.opcode != opDeltaChunk) continue;
    if (frame.offset + frame.total > walk.size) break;
    final Uint8List content = _content(
      await source.read(frame.offset, frame.total),
      frame.opcode,
    );
    final KeyframeDeltaState state;
    if (frame.opcode == opChunk) {
      state = keyframeDeltaStateFromChunk(content, chunkOffset: frame.offset);
      keyframe = state;
    } else {
      final FourdgsDeltaChunkBody body = parseDeltaChunk(content);
      final KeyframeDeltaState? reference =
          body.header.deltaMode == deltaModeKeyframe ? keyframe : previous;
      if (reference == null) {
        throw FourdgsMalformedFile(
          'the delta chunk at byte ${frame.offset} has no earlier state to reference',
        );
      }
      state = applyKeyframeDeltaBody(
        reference,
        body,
        chunkOffset: frame.offset,
      );
    }
    final _StateIdIndex? previousIds =
        previous == null ? null : _StateIdIndex(previous.ids);
    for (final int id in state.ids) {
      if (candidates.contains(id) && !(previousIds?.contains(id) ?? false)) {
        return id;
      }
    }
    previous = state;
  }
  return null;
}

/// A fixed one-mebibit identity filter. False positives take the exact replay
/// above; false negatives are impossible because add and lookup set/test the
/// same three bits.
class _IdentityFilter {
  static const int _byteCount = 1 << 17;
  static const int _bitMask = _byteCount * 8 - 1;

  final Uint8List _bits = Uint8List(_byteCount);

  bool mightContain(int id) {
    for (final int bit in _positions(id)) {
      if ((_bits[bit >> 3] & (1 << (bit & 7))) == 0) return false;
    }
    return true;
  }

  void add(int id) {
    for (final int bit in _positions(id)) {
      _bits[bit >> 3] |= 1 << (bit & 7);
    }
  }

  Iterable<int> _positions(int id) sync* {
    final int value = id & 0xFFFFFFFF;
    yield (value ^ (value >>> 16)) & _bitMask;
    yield ((value << 7) ^ (value >>> 9) ^ 0x5BD1E995) & _bitMask;
    yield ((value << 13) ^ (value >>> 11) ^ 0x27D4EB2D) & _bitMask;
  }
}

String _indexWhere(int i, int length, List<int> offsets) =>
    i < offsets.length
        ? 'the Chunk Index record at byte ${offsets[i]} (entry $i of $length)'
        : 'chunk index entry $i';

/// The bands an index entry names, decoded one at a time. True when one refused.
///
/// Shared by both models: a band record is a whole record class the framing walk
/// steps over, and a file whose band will not decode is a file every reader
/// refuses and a framing validator calls valid — which is what a `keyframe-delta`
/// file got here until this loop ran for it too.
///
/// The count a band must declare is the number of gaussians whose harmonics it
/// carries: a keyframe chunk's own count, and a Delta Chunk's `birth_count`,
/// since only a born gaussian brings harmonics with it (spec §11.5).
Future<bool> _checkBands(
  FourdgsReadable source,
  FourdgsChunkIndexEntry entry,
  int i,
  _Report report, {
  int? count,
  required int resourceSize,
  List<FourdgsBandRange>? framedBands,
}) async {
  for (final FourdgsBandRange band in entry.bands) {
    if (band.offset < 0 ||
        band.length < recordHeaderBytes ||
        band.offset + band.length > resourceSize) {
      report.error(
        'the ShBandStream range for band ${band.band} of index entry $i '
        'spans [${band.offset}, ${band.offset + band.length}), outside the '
        '$resourceSize-byte resource',
      );
      return true;
    }
    if (framedBands != null &&
        !framedBands.any(
          (FourdgsBandRange framed) =>
              framed.band == band.band &&
              framed.offset == band.offset &&
              framed.length == band.length,
        )) {
      report.error(
        'the Chunk Index range for SH band ${band.band} at '
        '[${band.offset}, ${band.offset + band.length}) does not belong to the '
        'Chunk at byte ${entry.chunkOffset}',
      );
      return true;
    }
  }
  if (framedBands != null) {
    final List<FourdgsBandRange> declared = List<FourdgsBandRange>.of(
      entry.bands,
    )..sort(_compareBandRanges);
    final List<FourdgsBandRange> physical = List<FourdgsBandRange>.of(
      framedBands,
    )..sort(_compareBandRanges);
    final bool exact =
        declared.length == physical.length &&
        declared.asMap().entries.every((MapEntry<int, FourdgsBandRange> item) {
          final FourdgsBandRange other = physical[item.key];
          return item.value.band == other.band &&
              item.value.offset == other.offset &&
              item.value.length == other.length;
        });
    if (!exact) {
      report.error(
        'Chunk Index entry $i declares SH band ranges '
        '${_bandRanges(declared)}, but the physical records following the '
        'state chunk at byte ${entry.chunkOffset} are '
        '${_bandRanges(physical)}; expected exact sets',
      );
      return true;
    }
  }
  if (entry.bands.isEmpty) return false;
  final int expectedCount;
  try {
    expectedCount = count ?? await _bandPopulation(source, entry);
  } on FourdgsException catch (error) {
    report.refused(
      'the chunk at byte ${fourdgsCommas(entry.chunkOffset)} does not say how '
      'many gaussians its bands carry: ',
      error,
      site: FourdgsRefusalSite(
        entry.chunkOffset,
        'the Chunk record at index entry $i',
      ),
    );
    return true;
  }
  for (final FourdgsBandRange band in entry.bands) {
    try {
      decodeShBandRecord(
        _content(await source.read(band.offset, band.length), opShBandStream),
        expectedBand: band.band,
        expectedCount: expectedCount,
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
      return true;
    }
  }
  return false;
}

int _compareBandRanges(FourdgsBandRange a, FourdgsBandRange b) {
  final int band = a.band.compareTo(b.band);
  if (band != 0) return band;
  final int offset = a.offset.compareTo(b.offset);
  return offset != 0 ? offset : a.length.compareTo(b.length);
}

String _bandRanges(List<FourdgsBandRange> ranges) =>
    <String>[
      for (final FourdgsBandRange range in ranges)
        '${range.band}:[${range.offset},${range.offset + range.length})',
    ].toString();

/// How many gaussians the bands of [entry] carry harmonics for.
Future<int> _bandPopulation(
  FourdgsReadable source,
  FourdgsChunkIndexEntry entry,
) async {
  if (entry.kind == 0) {
    // Twenty-four bytes of the chunk's own head, not the chunk.
    final int want =
        entry.chunkLength - recordHeaderBytes < chunkFixedHeadBytes
            ? entry.chunkLength - recordHeaderBytes
            : chunkFixedHeadBytes;
    return parseChunkInterval(
      await source.read(entry.chunkOffset + recordHeaderBytes, want),
      fileOffset: entry.chunkOffset + recordHeaderBytes,
    ).count;
  }
  return parseDeltaChunk(
    _content(
      await source.read(entry.chunkOffset, entry.chunkLength),
      opDeltaChunk,
    ),
  ).header.birthCount;
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
