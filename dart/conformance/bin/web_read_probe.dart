// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Compiles the read path to JavaScript, and exists only to be compiled.
///
/// `dart test` runs on the VM, where a Dart `int` is a real 64-bit integer.
/// JavaScript numbers are not, so a 64-bit literal anywhere in the compile
/// graph is a dart2js error no VM test can produce. Version 0.1.0 shipped with
/// three of them and could not be built for the web at all.
///
/// This file imports the umbrella library and nothing else; CI compiles it with
/// `dart compile js`. Run it yourself with:
///
/// ```
/// cd dart/conformance && dart compile js -o /tmp/probe.js bin/web_read_probe.dart
/// ```
///
/// **Do not import `package:fourdgs/writer.dart` here.** The encoder cannot be
/// compiled for the web by design — see that library's documentation — and its
/// absence from this graph is the property being checked.
///
/// `package:fourdgs/io.dart` is out of scope rather than uncompilable: it is
/// the `dart:io` transport, which a browser consumer does not import. It only
/// imports the umbrella and re-exports nothing, so it cannot widen this
/// library's surface.
///
/// The references below keep the read API in the compile graph rather than
/// tree-shaken away. Anything a web consumer touches belongs in the list.
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
