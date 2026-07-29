// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The `dart:io` transport: a [FourdgsReadable] over a file on disk.
///
/// A separate library rather than part of `package:fourdgs/fourdgs.dart` so that
/// importing the decoder never drags `dart:io` in. Transports live at the edges;
/// a browser build has no business seeing this one, and a program that reads
/// files pays one extra import for it.
library;

import 'dart:io';
import 'dart:typed_data';

import 'fourdgs.dart';

/// A file, read by byte range.
///
/// Opens the file once and issues positioned reads against the open handle,
/// which is what makes an indexed decode cost the ranges it asks for rather than
/// the file: reading an instant out of a 500 MiB scene reads the index and then
/// that instant, and never anything in between.
class FourdgsFileReadable implements FourdgsReadable {
  FourdgsFileReadable._(this._handle, this._size);

  /// Opens [path] for reading.
  static Future<FourdgsFileReadable> open(String path) async {
    final file = File(path);
    final size = await file.length();
    return FourdgsFileReadable._(await file.open(), size);
  }

  final RandomAccessFile _handle;
  final int _size;

  @override
  Future<int> size() async => _size;

  @override
  Future<Uint8List> read(int offset, int length) async {
    if (offset < 0 || length < 0 || offset + length > _size) {
      throw RangeError(
        '4dgs: range [$offset, ${offset + length}) outside $_size bytes',
      );
    }
    await _handle.setPosition(offset);
    final out = await _handle.read(length);
    // A short read is the one behaviour that breaks every caller, and a file can
    // produce one — it may have been truncated between the size call and this
    // read. Reported rather than returned.
    if (out.length != length) {
      throw FourdgsTruncatedFile(
        'read $length bytes at $offset and got ${out.length}',
      );
    }
    return out;
  }

  /// Closes the underlying handle.
  Future<void> close() => _handle.close();
}
