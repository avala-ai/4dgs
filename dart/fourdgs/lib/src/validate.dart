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
  int firstOpcode = -1;
  int chunkCount = 0;
  int counted = 0;
  final List<FourdgsChunkIndexEntry> index = <FourdgsChunkIndexEntry>[];
  // Where each entry's own Chunk Index record sits, so a finding about entry `i`
  // names the byte the reader would name for the same fault.
  final List<int> indexRecordOffsets = <int>[];
  final Map<int, FourdgsAudioSourceRecord> audioSources =
      <int, FourdgsAudioSourceRecord>{};
  final Map<int, int> audioData = <int, int>{};
  bool firstChunkSeen = false;
  // A front-matter refusal makes the reader passes below pointless: the reader
  // would refuse the same record for the same reason at the same byte, and a
  // report that says it twice is a report a reader has to read twice.
  bool frontMatterRefused = false;

  try {
    for (final FourdgsFrame frame in walk.records) {
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
      // A record whose own body will not parse is a finding rather than an
      // abort: the point of a validator is to say everything that is wrong with
      // a file, not the first thing.
      switch (frame.opcode) {
        case opHeader:
          try {
            header = FourdgsHeader.parse(await _bytesOf(source, frame));
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
          if (frame.opcode == opChunk) {
            try {
              // The first twenty-four bytes, not the record: a chunk is where a
              // file keeps its weight, and all this pass wants from one is the
              // count it declares. What is *in* it is checked by decoding it,
              // one chunk at a time, further down.
              counted +=
                  parseChunkInterval(
                    await _bytesOf(source, frame, most: chunkFixedHeadBytes),
                  ).count;
            } on FourdgsException catch (error) {
              report.error('chunk $chunkCount does not parse: ${_say(error)}');
            }
          }
        case opChunkIndex:
          try {
            index.add(
              FourdgsChunkIndexEntry.parse(
                await _bytesOf(source, frame),
                fileOffset: frame.offset + recordHeaderBytes,
              ),
            );
            indexRecordOffsets.add(frame.offset);
          } on FourdgsException catch (error) {
            report.error('a chunk index entry does not parse: ${_say(error)}');
          }
        case opFooter:
          try {
            footer = FourdgsFooter.parse(await _bytesOf(source, frame));
          } on FourdgsException catch (error) {
            report.error('Footer does not parse: ${_say(error)}');
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
            audioSources[parsed.sourceId] = parsed;
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

  if (footer != null && footer.summaryCrc != 0 && footer.summaryStart != 0) {
    // The Footer record itself is not covered: nine bytes of framing plus its
    // twenty bytes of content plus the trailing magic.
    final int tail = walk.size - (recordHeaderBytes + 20 + fourdgsMagic.length);
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
    // Opening the file the way a seeking client would is itself a check, and it
    // is the same check for both temporal models — the Footer is last, the tail
    // is where the tail should be, and every index entry obeys §5.8. The
    // keyframe-delta branch used to skip it and composed its chains straight
    // from the framing, which meant a delta file with a record after its Footer,
    // an unknown `chunk_kind` or a zero-width nonempty entry was reported valid
    // while every reader in the repository refused it.
    final FourdgsIndexedScene? scene;
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
      return FourdgsValidation(report.findings);
    }
    // The record families the framing walk steps over and a public decoder
    // refuses: a truncated ObjectTrack or a malformed CoordinateFrame is a file
    // `readFourdgsObjects` and `readFourdgsProvenance` decline, so a validator
    // that only framed them would call it valid.
    await _checkAuxiliaryRecords(source, scene, report);
    if (keyframeDelta) {
      await _checkKeyframeDelta(
        source,
        walk,
        scene,
        report,
        windows: windows,
        indexRecordOffsets: indexRecordOffsets,
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
      );
    }
  }

  return FourdgsValidation(report.findings);
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
  FourdgsIndexedScene scene,
  _Report report,
) async {
  try {
    await readFourdgsProvenance(source, scene);
  } on FourdgsException catch (error) {
    report.error('the provenance records do not decode: ${_say(error)}');
  }
  try {
    await readFourdgsObjects(source, scene);
  } on FourdgsException catch (error) {
    report.error('the object layer does not decode: ${_say(error)}');
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
    report.note(
      'reserved provenance record $hex — skipped, as required '
      '(0x26-0x2F, section 5.15.6)',
    );
  } else {
    report.note('unknown record $hex — skipped, as required');
  }
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
}) async {
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
    // The count the index promised, which `readFourdgsChunk` has just checked
    // the chunk's own header against.
    if (await _checkBands(
      source,
      entry,
      i,
      report,
      count: entry.gaussianCount,
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
}) async {
  final List<FourdgsChunkIndexEntry> index = scene.index;
  if (index.isEmpty) {
    // No index means no chain to walk by byte range, so the model's
    // front-to-back reader is the only path there is — and it takes the file,
    // because without an index there is nothing to address a chunk by. This is
    // the one place this validator holds more than a chunk, and it holds it for
    // a file that has already been reported as unseekable.
    try {
      decodeKeyframeDeltaStreamed(await source.read(0, walk.size));
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
  // Built once. Every chain walk needs this lookup, and building it per entry is
  // what makes validating a ten-thousand-entry index quadratic in the index
  // before a single chunk is read (AGENTS.md §4).
  final Map<int, FourdgsChunkIndexEntry> byOffset = keyframeDeltaChainIndex(
    index,
  );
  for (int i = 0; i < index.length; i++) {
    final FourdgsChunkIndexEntry entry = index[i];
    final String where =
        i < indexRecordOffsets.length
            ? 'the Chunk Index record at byte ${indexRecordOffsets[i]} '
                '(entry $i of ${index.length})'
            : 'chunk index entry $i';
    try {
      final KeyframeDeltaState state = await readKeyframeDeltaChain(
        source,
        index,
        entry,
        byOffset: byOffset,
      );
      // §5.8 defines `live_count` for every extended entry as the population
      // after composition, and the reference writers set it on keyframes too, so
      // both counts are checked — the same two the indexed reader checks, in the
      // same words, because a file the reader refuses and the validator passes
      // is the pair disagreeing about one file.
      if (entry.kind == 0 && entry.liveCount != state.count) {
        report.error(
          '$where declares live_count ${entry.liveCount} for a keyframe whose '
          'chunk holds ${state.count} gaussians; expected the two to agree',
        );
      }
      final int declared = indexEntryPopulation(entry, isKeyframeDelta: true);
      if (state.count != declared) {
        report.error(
          '$where declares $declared live gaussians over [${entry.t0}, '
          '${entry.t1}), but its chain composes to ${state.count}; expected the '
          'index and the chunks to agree',
        );
      }
      state.checkWindows(windows);
    } on FourdgsException catch (error) {
      report.refused(
        'a chunk does not compose: ',
        error,
        site: FourdgsRefusalSite(
          entry.chunkOffset,
          'the Chunk record at index entry $i',
        ),
      );
      return;
    }
    if (await _checkBands(source, entry, i, report)) return;
  }
}

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
}) async {
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
