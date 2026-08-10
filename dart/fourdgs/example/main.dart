// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Reads a `.4dgs` file two ways and prints what each path answers.
///
/// ```
/// dart run example/main.dart scene.4dgs
/// dart run example/main.dart scene.4dgs 1.5
/// ```
///
/// The two paths exist because they cost different things. A streamed read
/// decodes the whole file front to back and hands back every gaussian; an
/// indexed read fetches the tail, learns where everything is, and then transfers
/// only the chunks an instant needs. On a 500 MiB scene that is the difference
/// between reading 500 MiB and reading a few hundred kilobytes.
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
  final t = args.length > 1 ? double.parse(args[1]) : 0.0;

  // --- Indexed: open the file without decoding it -------------------------
  //
  // `openFourdgsIndexed` reads the head and the summary at the tail. It does
  // not touch a chunk, so this is the same cost for a 5 MiB file and a 5 GiB
  // one, and it is the right way to answer "what is in here".
  final source = await FourdgsFileReadable.open(path);
  try {
    final scene = await openFourdgsIndexed(source);
    final header = scene.header;
    stdout
      ..writeln('profile        ${header.profile}')
      ..writeln('written by     ${header.library}')
      ..writeln('duration       ${header.durationSec} s')
      ..writeln('gaussians      ${header.gaussianCount}')
      ..writeln('temporal model ${header.temporalModel}')
      ..writeln('SH degree      ${header.shDegree}')
      ..writeln('has audio      ${header.hasAudio}')
      ..writeln('chunks         ${scene.index.length}');

    // The seek rule is `t0 <= t < t1`, half-open, so an instant selects exactly
    // the chunks that cover it. `bytesForTime` prices the seek before it
    // happens, which is what lets a caller decide whether to make it.
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
  } on FourdgsException catch (e) {
    // Every refusal says which byte, which record, which value, and what was
    // expected — print it as it comes rather than replacing it with "could not
    // read file", which throws away the only useful part.
    stderr.writeln('4dgs: $e');
    exitCode = 65; // EX_DATAERR
    return;
  } finally {
    await source.close();
  }

  // --- Streamed: decode the whole file ------------------------------------
  //
  // The other path, for when you want every gaussian rather than an instant:
  // one pass, no seeking, and it works on a pipe. `recoverTruncated` returns
  // what arrived before a cut instead of throwing, with `truncated` set.
  final bytes = await File(path).readAsBytes();
  final scene = readFourdgsBytes(bytes, recoverTruncated: true);
  final cut = scene.truncated ? ', file was truncated' : '';

  if (scene.header.temporalModel == 'keyframe-delta') {
    // A keyframe-delta file has its own path, and this is why. Its chunks are
    // keyframes and deltas rather than a population, so the generic reader's
    // total counts operations — births, deaths and updates — not gaussians.
    // `decodeKeyframeDeltaStreamed` composes them, which is the number a caller
    // actually wants.
    final sequence = decodeKeyframeDeltaStreamed(bytes);
    stdout
      ..writeln('')
      ..writeln('streamed: ${sequence.chunks.length} state chunk(s)$cut')
      ..writeln(
        '  a population here is composed, not summed — see '
        'decodeKeyframeDeltaStreamed',
      );
  } else {
    stdout
      ..writeln('')
      ..writeln('streamed: ${scene.gaussians.count} gaussians$cut');
  }
}
