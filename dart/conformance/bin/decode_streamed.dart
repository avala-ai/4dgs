// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Conformance runner: streamed decode, canonical JSON to stdout.
///
/// The whole interface between an implementation and the harness is this: take a
/// path, print the canonical JSON. This runner declares support for every
/// variant — streaming is the path that works on a file with no index.
library;

import 'dart:io';

import 'package:fourdgs/fourdgs.dart';
import 'package:fourdgs_conformance/canonical.dart';
import 'package:fourdgs_conformance/checks.dart';

String run(String path) {
  final data = File(path).readAsBytesSync();
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
  } catch (error) {
    stderr.writeln(error);
    exit(1);
  }
}
