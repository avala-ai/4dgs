// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Conformance runner: streamed decode, canonical JSON to stdout.
///
/// The whole interface between an implementation and the harness is this: take a
/// path, print the canonical JSON. This runner declares support for every
/// variant — streaming is the path that works on a file with no index.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fourdgs/fourdgs.dart';
import 'package:fourdgs_conformance/canonical.dart';
import 'package:fourdgs_conformance/checks.dart';

/// The Header's temporal model, read without decoding the gaussians. A
/// `keyframe-delta` file composes and summarizes differently from a
/// `gaussian-birth` one, so the runner branches on this before doing either.
String? temporalModel(Uint8List data) {
  checkMagic(data);
  for (final record in iterRecords(data, fourdgsMagic.length)) {
    if (record.opcode == opHeader) {
      return FourdgsHeader.parse(record.content).temporalModel;
    }
  }
  return null;
}

String run(String path) {
  final data = File(path).readAsBytesSync();

  if (temporalModel(data) == 'keyframe-delta') {
    // The whole model exists to make reconstruction-at-an-instant cheap, and
    // that reconstruction — not a whole-population summary — is what the SDKs
    // are diffed on. Truncation recovery is a gaussian-birth check: the states
    // canonical is a different statement and a cut file is a different file.
    return canonical(
      keyframeDeltaStatesJson(decodeKeyframeDeltaStreamed(data)),
    );
  }

  final scene = readFourdgsBytes(data);

  checkTruncationRecovery(data, scene);

  return canonical(
    summarize(
      header: scene.header,
      gaussians: scene.gaussians,
      audioSources: scene.audioSources,
      chunkIntervals: <(double, double)>[
        for (final e in scene.chunkIndex) (e.t0, e.t1),
      ],
      camera: scene.camera,
      metadata: scene.metadata,
      attachments: scene.attachments,
      statistics: scene.statistics,
      summaryOffsets: scene.summaryOffsets,
      summaryCrcOk: scene.summaryCrcOk,
      provenance: scene.provenance,
      objects: scene.objects,
    ),
  );
}

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: decode_streamed <file.4dgs>');
    exit(2);
  }
  try {
    stdout.writeln(run(args.single));
  } on FourdgsException catch (error) {
    // A refusal is an answer, printed on stdout and exiting 0. Only this
    // library's own exceptions qualify: anything else — a bug in the runner, a
    // failed check from `checks.dart` — stays a crash, because a decoder must
    // not be able to pass the invalid corpus by falling over in roughly the
    // right place.
    stdout.writeln(refusalJson(error));
  } catch (error) {
    stderr.writeln(error);
    exit(1);
  }
}
