// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The encoder: `.4dgs` files written from gaussian state.
///
/// A separate library rather than part of `package:fourdgs/fourdgs.dart`, for
/// the same reason `package:fourdgs/io.dart` is one — except that here the cost
/// of merging them is not tidiness but a build that does not happen at all.
///
/// The chunk orderer spreads coordinates into a Morton code, and the masks that
/// do it are 64-bit values: `0x1249249249249249` and two of its neighbours. On
/// the web a Dart `int` IS a JavaScript number, so those literals are past
/// `2^53` and the compiler rejects them where they are written — not where they
/// are used. A read-only consumer that never encodes anything still could not
/// compile, because the umbrella library exported this one and an export is
/// enough to put a file in the compile graph.
///
/// That is exactly what happened: `mission_control`, a Flutter **web** app that
/// only ever reads `.4dgs`, could not be built at all while it depended on
/// version 0.1.0 of this package.
///
/// **The masks are not the bug and must not be "fixed".** The values genuinely
/// exceed `2^53`; a JavaScript number cannot hold them however they are
/// spelled. Computing them at runtime — shifting two 32-bit halves together,
/// `int.parse`, anything — makes the compiler stop complaining and makes the
/// codes silently wrong on the web, which trades a build failure for corrupt
/// output. The encoder is correct where a Dart `int` is a real 64-bit integer,
/// which is every native target and wasm, and it is honest about not being
/// available where one is not.
///
/// `flutter build web --wasm` does not avoid this either: Flutter still emits a
/// dart2js fallback bundle for browsers without wasm, so the JavaScript compile
/// runs regardless of what the app targets.
///
/// So: import this library to write, and expect it to be unavailable on the
/// web. Import `package:fourdgs/fourdgs.dart` to read, anywhere.
library;

export 'src/writer.dart';
