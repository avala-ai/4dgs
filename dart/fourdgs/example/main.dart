// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Reads a `.4dgs` file two ways and prints what each path answers.
///
/// ```
/// dart run example/main.dart scene.4dgs
/// dart run example/main.dart scene.4dgs 1.5
/// ```
///
/// The two paths exist because they cost different things. An indexed open
/// reads the head and the summary at the tail, learns where everything is, and
/// then transfers only the byte ranges an instant needs; on a 500 MiB scene
/// that is the difference between reading 500 MiB and reading a few hundred
/// kilobytes. A front-to-back read decodes the file from the first byte to the
/// last and hands back every gaussian, and it is the path that still answers
/// when the file was cut short.
///
/// Front to back does not mean incremental here. Every entry point on that path
/// — `readFourdgsBytes`, `decodeKeyframeDeltaStreamed`,
/// `decodeKeyframeDeltaIndexed` — takes a `Uint8List`, so the second half of
/// this example holds the whole file in memory. Nothing in the format requires
/// that: the walk never seeks backwards. But this package ships no `Stream`
/// decoder, and an example that mimed one would be describing a library that
/// does not exist. The way to not pay for the file is the first half.
library;

import 'dart:io';

import 'package:fourdgs/fourdgs.dart';
import 'package:fourdgs/io.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run example/main.dart <file.4dgs> [seconds]');
    exitCode = 64; // EX_USAGE
    return;
  }
  final path = args.first;
  final t = args.length > 1 ? double.tryParse(args[1]) : 0.0;
  if (t == null) {
    stderr.writeln('4dgs: not a number of seconds: ${args[1]}');
    exitCode = 64; // EX_USAGE
    return;
  }
  if (!await File(path).exists()) {
    stderr.writeln('4dgs: no such file: $path');
    exitCode = 66; // EX_NOINPUT
    return;
  }

  // The two passes are attempted independently, and that is the point rather
  // than tidiness. An indexed open needs the Footer and the summary block at
  // the tail, so a truncated file fails it — and a truncated file is precisely
  // the one the front-to-back reader can still recover a prefix of. Giving up
  // on the first refusal would leave the recovery below unreachable in the only
  // case it exists for.
  final indexedOk = await _indexed(path, t);
  final wholeFileOk = await _wholeFile(path, t);
  if (!indexedOk || !wholeFileOk) exitCode = 65; // EX_DATAERR
}

/// Opens the file by byte range and answers `t` out of the index.
///
/// Returns false when the file refused to be read this way.
Future<bool> _indexed(String path, double t) async {
  // `openFourdgsIndexed` reads the head and the summary at the tail. It does
  // not touch a chunk, so this is the same cost for a 5 MiB file and a 5 GiB
  // one, and it is the right way to answer "what is in here".
  final source = await FourdgsFileReadable.open(path);
  bool printed = false;
  try {
    final scene = await openFourdgsIndexed(source);
    final header = scene.header;
    printed = true;
    stdout
      ..writeln('profile        ${header.profile}')
      ..writeln('written by     ${header.library}')
      ..writeln('duration       ${header.durationSec} s')
      ..writeln('gaussians      ${header.gaussianCount}')
      ..writeln('temporal model ${header.temporalModel}')
      ..writeln('SH degree      ${header.shDegree}')
      ..writeln('has audio      ${header.hasAudio}')
      ..writeln('chunks         ${scene.index.length}')
      ..writeln('size           ${scene.resourceBytes} bytes');

    if (header.temporalModel == 'keyframe-delta') {
      _priceKeyframeDeltaSeek(scene, t);
    } else {
      await _readCoveringChunks(source, scene, t);
    }
    return true;
  } on FourdgsException catch (e) {
    // Every refusal says which byte, which record, which value, and what was
    // expected — print it as it comes rather than replacing it with "could not
    // read file", which throws away the only useful part.
    stderr.writeln('4dgs: indexed: $e');
    return false;
  } finally {
    // Separating the two passes, and only when the first one had something to
    // separate: a file that fails to open has printed nothing, and a stray
    // blank first line is a thing a reader has to stop and explain to itself.
    if (printed) stdout.writeln('');
    await source.close();
  }
}

/// The `gaussian-birth` seek: fetch and decode the chunks covering `t`.
Future<void> _readCoveringChunks(
  FourdgsReadable source,
  FourdgsIndexedScene scene,
  double t,
) async {
  // The seek rule is `t0 <= t < t1`, half-open, so an instant selects exactly
  // the chunks that cover it. `bytesForTime` prices the seek before it happens,
  // which is what lets a caller decide whether to make it.
  final covering = scene.chunksForTime(t);
  stdout
    ..writeln('')
    ..writeln(
      'at t = $t s: ${covering.length} chunk(s), '
      '${scene.bytesForTime(t)} bytes to transfer',
    );

  for (final entry in covering) {
    final chunk = await readFourdgsChunk(source, scene, entry);
    stdout.writeln(
      '  [${entry.t0}, ${entry.t1})  ${chunk.count} gaussians decoded',
    );
  }
}

/// The `keyframe-delta` seek, priced from the index and not yet paid.
void _priceKeyframeDeltaSeek(FourdgsIndexedScene scene, double t) {
  // Under this model a chunk is not self-contained. The entry covering `t` may
  // be a Delta Chunk — a patch on the chunk it references — so `readFourdgsChunk`
  // would refuse it: that function reads a Chunk record and a delta is a
  // different opcode. Reaching `t` means composing the entry's whole reference
  // chain back to a keyframe, and `chainFrom` reads that chain out of the index
  // alone, before a byte of chunk data is fetched.
  //
  // Which also makes `bytesForTime` the wrong number here: it prices the
  // covering chunk, and the seek pays for the chain.
  final covering = scene.chunksForTime(t);
  if (covering.isEmpty) {
    stdout
      ..writeln('')
      ..writeln('at t = $t s: no chunk covers this instant');
    return;
  }
  final entry = covering.first;
  final chain = chainFrom(scene.index, entry);
  final chainBytes = chain.fold<int>(
    0,
    (int sum, FourdgsChunkIndexEntry e) => sum + e.chunkLength,
  );
  stdout
    ..writeln('')
    ..writeln(
      'at t = $t s: [${entry.t0}, ${entry.t1}), '
      '${entry.kind == 0 ? 'a keyframe' : 'a delta'} at depth ${entry.depth}',
    )
    ..writeln(
      '  chain: 1 keyframe + ${chain.length - 1} delta(s), '
      '$chainBytes bytes to transfer',
    )
    ..writeln('  the index claims ${entry.liveCount} gaussians live here');
}

/// Decodes the file front to back, with the whole of it in memory.
///
/// Returns false when the file refused to be read this way.
Future<bool> _wholeFile(String path, double t) async {
  final bytes = await File(path).readAsBytes();
  try {
    // `recoverTruncated` returns what arrived before a cut instead of throwing,
    // with `truncated` set. That is the recovery the indexed open above cannot
    // offer: it needs a tail, and a cut file has none.
    final scene = readFourdgsBytes(bytes, recoverTruncated: true);
    final cut = scene.truncated ? ', file was truncated' : '';

    if (scene.header.temporalModel != 'keyframe-delta') {
      stdout.writeln('streamed: ${scene.gaussians.count} gaussians$cut');
      return true;
    }

    // A keyframe-delta file has its own readers, and this is why. Its chunks
    // are keyframes and patches rather than populations, so a total taken over
    // them counts operations — births, deaths and updates — and not gaussians;
    // the generic reader above skips the Delta Chunks it does not model, and
    // its `gaussians` are the keyframes' alone. `decodeKeyframeDeltaStreamed`
    // composes each chunk onto the state it references, which is the number a
    // caller actually wants.
    final sequence = decodeKeyframeDeltaStreamed(bytes);
    stdout.writeln('streamed: ${sequence.chunks.length} state chunk(s)$cut');

    // And the seeking client's answer for the same instant:
    // `decodeKeyframeDeltaIndexed` walks each entry's chain the way §11.8 says
    // to, and must land on the population the front-to-back pass reaches.
    final composed = decodeKeyframeDeltaIndexed(bytes).sequence;
    for (final chunk in composed.chunks) {
      if (chunk.t0 <= t && t < chunk.t1) {
        stdout.writeln(
          'composed at t = $t s: ${chunk.state.count} gaussians, '
          'by walking that chain',
        );
        break;
      }
    }
    return true;
  } on FourdgsException catch (e) {
    // The same treatment the indexed pass gives a refusal. Without it a file
    // that opens cleanly and then names an unsupported codec in some chunk the
    // instant never touched leaves the CLI with an unhandled stack trace and an
    // exit status that means "crashed", not "bad data".
    stderr.writeln('4dgs: streamed: $e');
    return false;
  }
}
