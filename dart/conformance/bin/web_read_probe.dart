// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Compiles the read path to JavaScript, and exists only to be compiled.
///
/// `dart test` runs on the VM, where a Dart `int` is a real 64-bit integer.
/// JavaScript numbers are not, so a 64-bit literal anywhere in the compile
/// graph is a dart2js error — and that is an error no VM test can produce,
/// however thorough it is. Version 0.1.0 shipped with three of them, and the
/// first anyone knew was a browser app that could not be built at all.
///
/// So this file imports the umbrella library and nothing else, and CI compiles
/// it with `dart compile js`. What it asserts is not what the decoder computes;
/// it is that a consumer who only reads `.4dgs` can build for the web. Run it
/// yourself with:
///
/// ```
/// cd dart/conformance && dart compile js -o /tmp/probe.js bin/web_read_probe.dart
/// ```
///
/// **Do not add an import of `package:fourdgs/writer.dart` here.** The encoder
/// cannot be compiled for the web by design — see that library's documentation
/// — and its absence from this graph is the property being checked.
///
/// The references below exist so that the read API is genuinely in the compile
/// graph rather than tree-shaken away before it can be checked. Anything a web
/// consumer touches belongs in this list.
library;

import 'package:fourdgs/fourdgs.dart';

void main() {
  final set = FourdgsGaussianSet.empty();
  final state = set.stateAt(0.0, cutoff: fourdgsDefaultCutoff);

  // Named so a reader of the output can tell the probe ran rather than merely
  // linked, and so nothing above is dead code to the compiler.
  print(
    <String, Object?>{
      'version': fourdgsPackageVersion,
      'formatVersion': fourdgsVersion,
      'gaussians': set.count,
      'visible': state.count,
      'defaultCutoff': fourdgsDefaultCutoff,
      'maxChunkDecodedBytes': maxChunkDecodedBytes,
      'opcodes': <int>[opHeader, opChunk, opFooter, opObjectTrack],
      'refusals': <String>[refusalMagicMismatch, refusalWindowIndexOutOfRange],
      'reader':
          <Object>[
            readFourdgsBytes,
            openFourdgsIndexed,
            readFourdgsChunk,
            assembleGaussians,
            decodeChunkStreams,
            decodeKeyframeDeltaStreamed,
            inspectFourdgs,
            validateFourdgs,
          ].length,
      'types':
          <Type>[
            FourdgsBytes,
            FourdgsHeader,
            FourdgsQuantization,
            FourdgsWindow,
            FourdgsChunkIndexEntry,
            FourdgsMalformedFile,
            FourdgsTruncatedFile,
            FourdgsObjectLayer,
            FourdgsProvenance,
          ].length,
    }.toString(),
  );
}
