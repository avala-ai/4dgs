// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

/// The one abstraction the decoder depends on.
///
/// A reader needs exactly two things from a resource: how big it is, and the
/// bytes in a range. Everything else — a file, an HTTP server, a cache, an
/// in-memory buffer — is a transport, and transports live at the edges so the
/// decoder can be tested without a network and shipped without a platform.
///
/// [size] is asynchronous because some transports only learn it from their
/// first response (an HTTP reader reads it off `Content-Range`), and pretending
/// otherwise would push a blocking probe into every implementation.
abstract class FourdgsReadable {
  /// Total size of the resource in bytes.
  Future<int> size();

  /// Exactly [length] bytes at [offset], or a thrown error.
  ///
  /// Returning a short read silently is the one behaviour that breaks every
  /// caller, so implementations must not do it.
  Future<Uint8List> read(int offset, int length);
}

/// A whole resource already in memory.
class FourdgsBytes implements FourdgsReadable {
  FourdgsBytes(this.bytes);

  final Uint8List bytes;

  @override
  Future<int> size() async => bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    if (offset < 0 || length < 0 || offset + length > bytes.length) {
      throw RangeError(
        '4dgs: range [$offset, ${offset + length}) outside ${bytes.length} bytes',
      );
    }
    return Uint8List.sublistView(bytes, offset, offset + length);
  }
}
