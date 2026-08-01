// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Conformance runner: indexed decode.
///
/// Reads the Footer, then the index, then each chunk by byte range — the path a
/// seeking client takes — and produces the same canonical JSON the streamed
/// runner does. Agreeing with itself across two very different read paths is
/// most of what makes an indexed implementation trustworthy.
///
/// `run.py` runs this one only on variants whose name carries `UseChunkIndex`:
/// a file written without an index cannot be read this way, and declining is the
/// correct answer rather than a failure.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fourdgs/fourdgs.dart';
import 'package:fourdgs/io.dart';
import 'package:fourdgs_conformance/canonical.dart';
import 'package:fourdgs_conformance/checks.dart';

/// Every band this version defines, so the summary sees the coefficients the
/// file carries rather than the ones a default happened to admit.
const int allBands = 3;

/// The Header's temporal model, read from the front without decoding gaussians.
String? temporalModel(Uint8List data) {
  checkMagic(data);
  for (final record in iterRecords(data, fourdgsMagic.length)) {
    if (record.opcode == opHeader) {
      return FourdgsHeader.parse(record.content).temporalModel;
    }
  }
  return null;
}

Future<String> run(String path) async {
  final data = File(path).readAsBytesSync();
  if (temporalModel(data) == 'keyframe-delta') {
    // Read the Footer, then the index, then compose each chunk by walking its
    // chain — the seeking client's path — and emit the same states canonical the
    // streamed runner does. Agreeing across the two paths is most of what makes
    // an indexed keyframe-delta reader trustworthy.
    return canonical(
      keyframeDeltaStatesJson(decodeKeyframeDeltaIndexed(data).sequence),
    );
  }

  final file = await FourdgsFileReadable.open(path);
  final source = CountingReadable(file);
  try {
    final scene = await openFourdgsIndexed(source);

    final chunks = <FourdgsDecodedChunk>[];
    for (final entry in scene.index) {
      chunks.add(
        await readFourdgsChunk(source, scene, entry, maxShBand: allBands),
      );
    }
    final audioSources = await readFourdgsAudioSources(source, scene);
    final camera = await readFourdgsCamera(source, scene);
    final metadata = await readFourdgsMetadata(source, scene);
    final attachments = await readFourdgsAttachments(source, scene);
    final provenance = await readFourdgsProvenance(source, scene);
    final objects = await readFourdgsObjects(source, scene);

    await checkBandRangeSkipping(source, scene);

    final sh =
        scene.header.shDegree == 0
            ? null
            : mergeChunkBands(
              <int>[for (final c in chunks) c.count],
              <Map<int, Uint8List>>[for (final c in chunks) c.shBands],
            );

    return canonical(
      summarize(
        header: scene.header,
        gaussians: assembleGaussians(chunks, scene.header.shDegree, sh: sh),
        audioSources: audioSources,
        chunkIntervals: <(double, double)>[
          for (final e in scene.index) (e.t0, e.t1),
        ],
        camera: camera,
        metadata: metadata,
        attachments: attachments,
        statistics: scene.statistics,
        summaryOffsets: scene.summaryOffsets,
        summaryCrcOk: scene.summaryCrcOk,
        provenance: provenance,
        objects: objects,
      ),
    );
  } finally {
    await file.close();
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: decode_indexed <file.4dgs>');
    exit(2);
  }
  try {
    stdout.writeln(await run(args.single));
  } catch (error) {
    stderr.writeln(error);
    exit(1);
  }
}
