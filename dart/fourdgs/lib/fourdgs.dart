// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// A decoder for the `.4dgs` container: a single, self-contained, seekable file
/// holding a 4D gaussian splat scene — gaussians whose position, opacity and
/// existence vary continuously over time, optionally with an embedded audio
/// sources and a default camera trajectory.
///
/// The format is renderer-agnostic and so is this decoder. It reconstructs
/// splat state at a given time and stops there; how that state is drawn is out
/// of scope, and nothing here knows or cares.
///
/// Two read paths are provided because they catch different mistakes:
///
/// * [readFourdgsBytes] walks a whole file front to back. It needs no index and
///   survives a truncated file.
/// * [openFourdgsIndexed] reads the Footer, then the index, then only the byte
///   ranges an instant needs. It is the path a seeking client takes.
///
/// The only thing either needs from the outside world is a [FourdgsReadable] —
/// something that can report its size and read a byte range. Transports live at
/// the edges, so the decoder can be tested without a network and shipped
/// without a platform.
///
/// Writing goes the other way through the same primitives:
/// [writeFourdgsToSink] and [writeKeyframeDeltaToSink] emit bounded records;
/// [writeFourdgsBytes] and [writeKeyframeDeltaBytes] are their in-memory
/// conveniences. They encode gaussian state in their own right rather than
/// wrapping another SDK, which is what makes their agreement with those SDKs
/// worth something.
///
/// Reading a file from disk needs one more import: `package:fourdgs/io.dart`
/// carries the `dart:io` transport, kept out of this library so the decoder
/// itself stays platform-free and usable in a browser.
///
/// The normative specification is at <https://github.com/avala-ai/4dgs>.
library;

export 'src/chunk_decoder.dart';
export 'src/exceptions.dart';
export 'src/indexed_reader.dart';
export 'src/keyframe_delta.dart';
export 'src/model.dart';
export 'src/objects.dart';
export 'src/opcode.dart';
export 'src/provenance.dart';
export 'src/quantization.dart';
export 'src/readable.dart';
export 'src/records.dart';
export 'src/serialization.dart';
export 'src/stream_reader.dart';
export 'src/writer.dart';

/// This package's version, and the single source of truth for it.
///
/// The release workflow asserts that this constant, `pubspec.yaml` and the
/// release tag all agree, and refuses the release when they do not — a version
/// number is the one mistake that cannot be corrected after publication.
const String fourdgsPackageVersion = '0.1.0';
