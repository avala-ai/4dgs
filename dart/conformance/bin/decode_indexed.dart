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
import 'package:fourdgs_conformance/optional_identity.dart';

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

Future<String> run(
  String path, {
  int maxDecodedStateBytes = defaultMaxDecodedStateBytes,
}) async {
  final data = File(path).readAsBytesSync();
  bool keyframeDelta = false;
  try {
    keyframeDelta = temporalModel(data) == 'keyframe-delta';
  } on FourdgsException {
    // This probe chooses between two indexed decoders; it is not validation.
    // If the leading bytes or Header are invalid, fall through to the ordinary
    // indexed opener so the advertised indexed refusal is actually exercised.
  }
  if (keyframeDelta) {
    // Read the Footer, then the index, then compose each chunk by walking its
    // chain — the seeking client's path — and emit the same states canonical the
    // streamed runner does. Agreeing across the two paths is most of what makes
    // an indexed keyframe-delta reader trustworthy.
    final sequence =
        decodeKeyframeDeltaIndexed(
          data,
          maxDecodedStateBytes: maxDecodedStateBytes,
        ).sequence;
    return canonical(
      isOptionalIdentityWitness(sequence.header)
          ? keyframeDeltaIdentityJson(sequence)
          : keyframeDeltaStatesJson(sequence),
    );
  }

  final decodedStateBudget = FourdgsDecodedStateBudget(maxDecodedStateBytes);
  final file = await FourdgsFileReadable.open(path);
  final source = CountingReadable(file);
  try {
    final scene = await openFourdgsIndexed(source);

    // This proof performs incremental reads and retains none of them. Run it
    // before the collector starts accruing results, but share the injected
    // budget so even its first decoded allocation observes the caller limit.
    await checkBandRangeSkipping(
      source,
      scene,
      decodedStateBudget: decodedStateBudget,
    );

    final chunks = <FourdgsDecodedChunk>[];
    for (final entry in scene.index) {
      chunks.add(
        await readFourdgsChunk(
          source,
          scene,
          entry,
          maxShBand: allBands,
          decodedStateBudget: decodedStateBudget,
        ),
      );
      decodedStateBudget.retain(
        decodedChunkStateBytes(chunks.last),
        'indexed Chunk collection after byte ${entry.chunkOffset}',
      );
    }
    final audioSources = await readFourdgsAudioSources(source, scene);
    final camera = await readFourdgsCamera(source, scene);
    final metadata = await readFourdgsMetadata(source, scene);
    final attachments = await readFourdgsAttachments(source, scene);
    final provenance = await readFourdgsProvenance(source, scene);
    final objects = await readFourdgsObjects(source, scene);

    final counts = <int>[for (final c in chunks) c.count];
    final bands = <Map<int, Uint8List>>[for (final c in chunks) c.shBands];
    decodedStateBudget.retain(
      mergedShStateBytes(counts, bands),
      'gaussian-birth SH band assembly',
    );
    final sh =
        scene.header.shDegree == 0 ? null : mergeChunkBands(counts, bands);

    final whole = assembleGaussians(
      chunks,
      scene.header.shDegree,
      sh: sh,
      decodedStateBudget: decodedStateBudget,
    );

    if (isOptionalIdentityWitness(scene.header)) {
      return canonical(gaussianBirthIdentityJson(whole));
    }

    // Everything above this line assembles the whole scene, which is exactly why
    // it cannot see a gaussian filed in the wrong chunk: the summary carries it
    // anyway, and both read paths agree about it. This selects instead — only
    // the entries covering an instant — and requires the state they give to be
    // the state the whole scene gives. A partition that loses a gaussian from a
    // seek fails here and nowhere else.
    //
    // This always proves complete per-resident support containment. Candidate
    // probes are additional evidence where reachable, but a point-supported
    // scene may need none once every resident is already proved inside its
    // owning entry.
    await checkSeekReadsOnlyWhatItNeeds(
      source,
      scene,
      whole,
      decodedChunks: chunks,
    );

    return canonical(
      summarize(
        header: scene.header,
        gaussians: whole,
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
  final parsed = _parseArguments(args);
  if (parsed == null) {
    stderr.writeln(
      'usage: decode_indexed [--max-decoded-state-bytes N] <file.4dgs>',
    );
    exit(2);
  }
  try {
    stdout.writeln(
      await run(parsed.path, maxDecodedStateBytes: parsed.maxDecodedStateBytes),
    );
  } on FourdgsReaderLimit {
    stdout.writeln('{"unsupported":"resource-limit"}');
  } on FourdgsException catch (error) {
    // Both read paths answer the invalid corpus, and they reach the Header by
    // different routes — one front to back, one through the Footer. A check
    // placed on only one of them refuses half the files it should, and only
    // running both can show that. The same rule about what counts as an answer
    // holds on this route: only an error the refusal table names is one, and
    // anything else goes to stderr with a non-zero exit. See [refusalAnswer].
    final String? answer = refusalAnswer(error);
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
