// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Conformance runner: encode.
///
/// Decode a variant, re-encode the gaussians it yields with the reference
/// preset, and write the result. The gate around this
/// (`tests/conformance/encode_roundtrip.py`) re-encodes the same variant with
/// the Rust reference and requires the Python decoder to read both files
/// identically. Dart is a genuine second encoder rather than a binding, so that
/// agreement is a real cross-implementation claim: two encoders quantizing onto
/// the same grids produce files that decode to the same scene.
///
/// The preset mirrors `rust/conformance/src/bin/encode_gaussians.rs`. Byte
/// layout — how well deflate did, which order gaussians sit in a chunk —
/// legitimately differs between two encoders, so the gate compares decoded
/// content rather than bytes.
///
/// Usage: encode_roundtrip <in.4dgs> <out.4dgs>
library;

import 'dart:io';

import 'package:fourdgs/fourdgs.dart';

/// The gaussians alone: no audio, no camera, no metadata records, no
/// attachments, no provenance. That is the whole point of this baseline — these
/// authoring surfaces write gaussians, and a gate that compared whole scenes
/// would fail on the extras rather than on the encode.
String run(String input, String output) {
  final scene = readFourdgsBytes(File(input).readAsBytesSync());
  final bytes = writeFourdgsBytes(
    scene.gaussians,
    scene.header.durationSec,
    options: FourdgsWriteOptions(
      cutoff: scene.header.cutoff,
      writeIndex: true,
      writeStatistics: true,
      writeSummaryOffsets: true,
      writeCrc: true,
      shBands: 3,
      sceneProfile: scene.header.profile,
      attributes: scene.header.attributes,
    ),
  );

  // Two encodes of one scene must be the same bytes. An encoder that iterates a
  // map, or sorts unstably, passes every value-based check and still produces a
  // file that differs between runs — which is a property nobody notices until a
  // build is expected to reproduce.
  final again = writeFourdgsBytes(
    scene.gaussians,
    scene.header.durationSec,
    options: FourdgsWriteOptions(
      cutoff: scene.header.cutoff,
      writeIndex: true,
      writeStatistics: true,
      writeSummaryOffsets: true,
      writeCrc: true,
      shBands: 3,
      sceneProfile: scene.header.profile,
      attributes: scene.header.attributes,
    ),
  );
  if (bytes.length != again.length) {
    throw StateError('two encodes of one scene differ in length');
  }
  for (int i = 0; i < bytes.length; i++) {
    if (bytes[i] != again[i]) {
      throw StateError('two encodes of one scene differ at byte $i');
    }
  }

  final reread = readFourdgsBytes(bytes);
  if (reread.gaussians.count != scene.gaussians.count) {
    throw StateError(
      'the encoder wrote ${reread.gaussians.count} gaussians for '
      '${scene.gaussians.count}',
    );
  }

  File(output).writeAsBytesSync(bytes);
  return '${reread.gaussians.count} gaussians, '
      '${reread.chunkIndex.length} chunks, ${bytes.length} bytes, deterministic';
}

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: encode_roundtrip <in.4dgs> <out.4dgs>');
    exit(2);
  }
  try {
    stdout.writeln(run(args[0], args[1]));
  } catch (error) {
    stderr.writeln(error);
    exit(1);
  }
}
