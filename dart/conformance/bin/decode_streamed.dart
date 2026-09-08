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
import 'package:fourdgs_conformance/optional_identity.dart';

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

String run(
  String path, {
  int maxDecodedStateBytes = defaultMaxDecodedStateBytes,
}) {
  final data = File(path).readAsBytesSync();

  if (temporalModel(data) == 'keyframe-delta') {
    // The whole model exists to make reconstruction-at-an-instant cheap, and
    // that reconstruction — not a whole-population summary — is what the SDKs
    // are diffed on. Truncation recovery is a gaussian-birth check: the states
    // canonical is a different statement and a cut file is a different file.
    final sequence = decodeKeyframeDeltaStreamed(
      data,
      maxDecodedStateBytes: maxDecodedStateBytes,
    );
    return canonical(
      isOptionalIdentityWitness(sequence.header)
          ? keyframeDeltaIdentityJson(sequence)
          : keyframeDeltaStatesJson(sequence),
    );
  }

  final scene = readFourdgsBytes(
    data,
    maxDecodedStateBytes: maxDecodedStateBytes,
  );

  checkTruncationRecovery(
    data,
    scene,
    maxDecodedStateBytes: maxDecodedStateBytes,
  );

  if (isOptionalIdentityWitness(scene.header)) {
    return canonical(gaussianBirthIdentityJson(scene.gaussians));
  }

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
  final parsed = _parseArguments(args);
  if (parsed == null) {
    stderr.writeln(
      'usage: decode_streamed [--max-decoded-state-bytes N] <file.4dgs>',
    );
    exit(2);
  }
  try {
    stdout.writeln(
      run(parsed.path, maxDecodedStateBytes: parsed.maxDecodedStateBytes),
    );
  } on FourdgsReaderLimit {
    stdout.writeln('{"unsupported":"resource-limit"}');
  } on FourdgsException catch (error) {
    // Only named refusals are answers. Unnamed decoder errors and runner bugs
    // remain failures, so crashing cannot pass an invalid-corpus case.
    final String? answer = refusalAnswer(
      error,
      structuredLateFrontMatter: true,
    );
    if (answer == null) {
      stderr.writeln('${parsed.path}: $error');
      exit(1);
    }
    stdout.writeln(answer);
  } catch (error) {
    stderr.writeln(error);
    exit(1);
  }
}

({String path, int maxDecodedStateBytes})? _parseArguments(List<String> args) {
  if (args.length == 1) {
    return (
      path: args.single,
      maxDecodedStateBytes: defaultMaxDecodedStateBytes,
    );
  }
  if (args.length != 3 || args.first != '--max-decoded-state-bytes') {
    return null;
  }
  if (!RegExp(r'^[0-9]+$').hasMatch(args[1])) return null;
  final value = int.tryParse(args[1]);
  if (value == null || value <= 0) return null;
  return (path: args[2], maxDecodedStateBytes: value);
}
