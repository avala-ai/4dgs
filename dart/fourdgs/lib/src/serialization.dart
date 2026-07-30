// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Primitives: the magic, record framing, and attribute-stream coding.
///
/// Everything on the wire goes through this file, so a reader only has to trust
/// one implementation of "read a length-prefixed thing without walking off the
/// end".
///
/// The framing rule the format depends on is enforced here rather than
/// remembered by callers: every record carries its own length, so an unknown
/// opcode is skipped by arithmetic instead of by guesswork, and a record that
/// has grown fields this reader does not know about is still exactly as long as
/// it says it is.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'exceptions.dart';
import 'opcode.dart';

/// `0x89 4 D G S 1 CR LF`.
///
/// The high bit stops byte-oriented tooling treating the file as text; the `1`
/// is the major version; the CR LF catches transports that mangle line endings,
/// which is a real failure mode for binary payloads served as text.
final Uint8List fourdgsMagic = Uint8List.fromList(<int>[
  0x89,
  0x34,
  0x44,
  0x47,
  0x53,
  0x31,
  0x0D,
  0x0A,
]);

/// Major version this reader implements.
const int fourdgsVersion = 1;

/// `u8 opcode` + `u64 content_length`.
const int recordHeaderBytes = 9;

/// `u8` ×5 + `u32 element_count` + `u64 payload_length`.
const int streamHeaderBytes = 17;

/// A crafted length must not be able to make a reader allocate before it has
/// been checked against the resource. Streams above this are refused outright.
const int maxStreamBytes = 512 * 1024 * 1024;

/// A bounds-checked read head over a byte buffer.
class FourdgsCursor {
  FourdgsCursor(this.bytes, [this.pos = 0]) : _bd = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData _bd;
  int pos;

  int get remaining => bytes.length - pos;

  Uint8List take(int n) {
    if (n < 0 || pos + n > bytes.length) {
      throw FourdgsTruncatedFile(
        'need $n bytes at offset $pos, $remaining remain',
      );
    }
    final out = Uint8List.sublistView(bytes, pos, pos + n);
    pos += n;
    return out;
  }

  /// Advances past [n] bytes without materializing them — how an unknown record
  /// is skipped.
  void skip(int n) {
    if (n < 0 || pos + n > bytes.length) {
      throw FourdgsTruncatedFile(
        'cannot skip $n bytes at offset $pos, $remaining remain',
      );
    }
    pos += n;
  }

  int u8() {
    if (pos + 1 > bytes.length) {
      throw FourdgsTruncatedFile('need 1 byte at offset $pos');
    }
    return _bd.getUint8(pos++);
  }

  int u16() {
    if (pos + 2 > bytes.length) {
      throw FourdgsTruncatedFile('need 2 bytes at offset $pos');
    }
    final v = _bd.getUint16(pos, Endian.little);
    pos += 2;
    return v;
  }

  int u32() {
    if (pos + 4 > bytes.length) {
      throw FourdgsTruncatedFile('need 4 bytes at offset $pos');
    }
    final v = _bd.getUint32(pos, Endian.little);
    pos += 4;
    return v;
  }

  /// A `u64`, read as two `u32`s on purpose.
  ///
  /// `ByteData.getUint64` is unsupported when Dart compiles to JavaScript, so a
  /// decoder that used it would work in tests and on Wasm and throw in a
  /// JS-compiled build — the worst possible place to find out. Splitting the
  /// read costs nothing and behaves identically everywhere.
  ///
  /// Values above 2^53 cannot be represented exactly by every Dart backend, and
  /// no honest length in this format approaches that, so one is a corrupt or
  /// hostile file rather than a large one.
  int u64() {
    if (pos + 8 > bytes.length) {
      throw FourdgsTruncatedFile('need 8 bytes at offset $pos');
    }
    final lo = _bd.getUint32(pos, Endian.little);
    final hi = _bd.getUint32(pos + 4, Endian.little);
    pos += 8;
    if (hi > 0x1FFFFF) {
      throw FourdgsMalformedFile(
        '64-bit length at offset ${pos - 8} exceeds 2^53 and cannot be a real length',
      );
    }
    return hi * 0x100000000 + lo;
  }

  double f64() {
    if (pos + 8 > bytes.length) {
      throw FourdgsTruncatedFile('need 8 bytes at offset $pos');
    }
    final v = _bd.getFloat64(pos, Endian.little);
    pos += 8;
    return v;
  }

  List<double> f32s(int n) {
    if (pos + 4 * n > bytes.length) {
      throw FourdgsTruncatedFile('need ${4 * n} bytes at offset $pos');
    }
    final out = List<double>.filled(n, 0);
    for (int i = 0; i < n; i++) {
      out[i] = _bd.getFloat32(pos + 4 * i, Endian.little);
    }
    pos += 4 * n;
    return out;
  }

  List<double> f64s(int n) {
    final out = List<double>.filled(n, 0);
    for (int i = 0; i < n; i++) {
      out[i] = f64();
    }
    return out;
  }

  /// `u32` byte length then that many UTF-8 bytes. Not NUL-terminated.
  String string() => utf8.decode(take(u32()));

  /// `u64` byte length then that many bytes.
  Uint8List blob() => take(u64());

  /// `u32` byte length of the whole block, then `string` key / `string` value
  /// pairs filling exactly that block.
  Map<String, String> strMap() {
    final block = FourdgsCursor(take(u32()));
    final out = <String, String>{};
    while (block.remaining > 0) {
      final key = block.string();
      out[key] = block.string();
    }
    return out;
  }
}

/// One framed record: its opcode, its content, and where it started.
///
/// The offset is kept because the Chunk Index addresses records by their opcode
/// byte, so a reader that found a record while scanning can hand its position
/// to a reader that will later range-read it.
class FourdgsRecord {
  const FourdgsRecord({
    required this.opcode,
    required this.content,
    required this.offset,
  });

  final int opcode;
  final Uint8List content;

  /// Offset of this record's opcode byte within the enclosing buffer.
  final int offset;

  /// Total framed size: header plus content.
  int get framedLength => recordHeaderBytes + content.length;
}

FourdgsRecord readRecord(FourdgsCursor cursor) {
  final offset = cursor.pos;
  final opcode = cursor.u8();
  final length = cursor.u64();
  return FourdgsRecord(
    opcode: opcode,
    content: cursor.take(length),
    offset: offset,
  );
}

/// Every record in [buf] from [pos], interpreting nothing.
///
/// A caller that does not recognize an opcode simply ignores the record — that
/// is the whole forward-compatibility story, and it works because this loop
/// never needs to know what a record means in order to know how long it is.
Iterable<FourdgsRecord> iterRecords(Uint8List buf, [int pos = 0]) sync* {
  final cursor = FourdgsCursor(buf, pos);
  while (cursor.remaining >= recordHeaderBytes) {
    yield readRecord(cursor);
  }
  // Fewer than nine bytes left. That is either the trailing magic, which is
  // where a whole file ends, or the front of a record header that never
  // arrived. Treating the second as a clean end of file is how a truncated
  // download reports itself as complete, so it is called what it is.
  if (cursor.remaining != 0 && !_isTrailingMagic(buf, cursor.pos)) {
    throw FourdgsTruncatedFile(
      '${cursor.remaining} trailing bytes are neither a record nor the closing magic',
    );
  }
}

bool _isTrailingMagic(Uint8List buf, int at) {
  if (buf.length - at != fourdgsMagic.length) return false;
  for (int i = 0; i < fourdgsMagic.length; i++) {
    if (buf[at + i] != fourdgsMagic[i]) return false;
  }
  return true;
}

/// Where a record sits, without reading what is in it.
class FourdgsRecordSpan {
  const FourdgsRecordSpan({
    required this.opcode,
    required this.offset,
    required this.contentOffset,
    required this.contentLength,
  });

  final int opcode;

  /// Offset of the opcode byte.
  final int offset;

  final int contentOffset;
  final int contentLength;

  /// One past the last byte of this record.
  int get end => contentOffset + contentLength;

  /// Total framed size: header plus content.
  int get framedLength => recordHeaderBytes + contentLength;
}

/// Walks record *headers* in [buf] from [pos], without requiring their content
/// to be present.
///
/// [iterRecords] cannot do this: it slices each record's content, so a buffer
/// holding only the front of a file throws as soon as it reaches a record
/// bigger than what was read — and the first Chunk, or an embedded audio track,
/// is exactly such a record. A reader opening a large file over byte ranges
/// needs to walk past those to find what it is looking for, and needs their
/// offsets rather than their bytes.
///
/// Iteration stops when a record's own 9-byte header no longer fits.
Iterable<FourdgsRecordSpan> scanRecordSpans(
  Uint8List buf, [
  int pos = 0,
]) sync* {
  final cursor = FourdgsCursor(buf, pos);
  while (cursor.remaining >= recordHeaderBytes) {
    final offset = cursor.pos;
    final opcode = cursor.u8();
    final length = cursor.u64();
    final span = FourdgsRecordSpan(
      opcode: opcode,
      offset: offset,
      contentOffset: cursor.pos,
      contentLength: length,
    );
    yield span;
    if (span.end > buf.length) return; // the rest of this record was not read
    cursor.pos = span.end;
  }
}

/// Refuses a file this reader must not try to interpret.
///
/// A wrong major version is refused rather than guessed at: the version byte
/// gates the whole file, so pressing on would mean reading unknown bytes as
/// known ones.
void checkMagic(Uint8List head) {
  if (head.length < fourdgsMagic.length) {
    throw const FourdgsTruncatedFile('file is shorter than the magic');
  }
  for (int i = 0; i < fourdgsMagic.length; i++) {
    if (head[i] != fourdgsMagic[i]) {
      if (head.length >= 5 &&
          head[1] == 0x34 &&
          head[2] == 0x44 &&
          head[3] == 0x47 &&
          head[4] == 0x53) {
        // The version is the ASCII digit in the magic, so it is reported as the
        // character a reader would see in a hex dump. Printing its ordinal
        // instead turns "version 9" into "version 57", which sends whoever is
        // holding the file looking for a version that does not exist.
        throw FourdgsUnsupportedVersion(
          '4dgs major version ${_versionLabel(head)} is not supported by this reader',
        );
      }
      throw const FourdgsUnsupportedVersion('not a 4dgs file (bad magic)');
    }
  }
}

/// The version byte as a reader would see it: the digit when it is one, and the
/// raw byte in hex when the file is corrupt enough that it is not.
String _versionLabel(Uint8List head) {
  if (head.length <= 5) return '(absent)';
  final byte = head[5];
  if (byte >= 0x30 && byte <= 0x39) return String.fromCharCode(byte);
  return '0x${byte.toRadixString(16).padLeft(2, '0')}';
}

/// One decoded attribute stream: `values[i * channels + c]`.
class FourdgsAttributeStream {
  const FourdgsAttributeStream({
    required this.attributeId,
    required this.channels,
    required this.count,
    required this.values,
  });

  final int attributeId;
  final int channels;
  final int count;

  /// Signed integer bins, `count * channels` of them.
  ///
  /// `Int32List` rather than a 64-bit list is exact, not a compromise: the
  /// encoder refuses to write a symbol whose zigzag exceeds 32 bits, so every
  /// bin that can legally appear fits a signed 32-bit integer.
  final Int32List values;
}

/// An attribute stream's header, read without touching its payload.
class FourdgsStreamHeader {
  const FourdgsStreamHeader({
    required this.attributeId,
    required this.width,
    required this.mode,
    required this.codec,
    required this.channels,
    required this.count,
    required this.payloadLength,
  });

  final int attributeId;
  final int width;
  final int mode;
  final int codec;
  final int channels;
  final int count;
  final int payloadLength;
}

/// Reads a stream's header and leaves [cursor] on its payload.
///
/// Separate from [decodeAttributeStream] so a caller can decide whether it
/// wants a stream — and whether the shape it declares is one it will accept —
/// *before* anything is decompressed or allocated. A reader that decodes first
/// and validates afterwards has already paid for whatever the header asked for.
FourdgsStreamHeader readStreamHeader(FourdgsCursor cursor) {
  if (cursor.remaining < streamHeaderBytes) {
    throw const FourdgsTruncatedFile('truncated attribute stream header');
  }
  return FourdgsStreamHeader(
    attributeId: cursor.u8(),
    width: cursor.u8(),
    mode: cursor.u8(),
    codec: cursor.u8(),
    channels: cursor.u8(),
    count: cursor.u32(),
    payloadLength: cursor.u64(),
  );
}

/// Steps over a stream whose header has been read, without decoding it.
///
/// How a private or unrecognized attribute is passed by: the registry reserves
/// ids 64–127 for applications and requires readers to skip them, and skipping
/// means not decompressing — a private stream in a codec this build lacks must
/// not fail a file that is otherwise perfectly readable.
void skipStreamPayload(FourdgsCursor cursor, FourdgsStreamHeader header) =>
    cursor.skip(header.payloadLength);

/// Reads one attribute stream from [cursor].
FourdgsAttributeStream decodeAttributeStream(FourdgsCursor cursor) =>
    decodeAttributeStreamBody(cursor, readStreamHeader(cursor));

/// Decodes the payload of a stream whose header has already been read.
FourdgsAttributeStream decodeAttributeStreamBody(
  FourdgsCursor cursor,
  FourdgsStreamHeader header,
) {
  final attributeId = header.attributeId;
  final width = header.width;
  final mode = header.mode;
  final codec = header.codec;
  final channels = header.channels;
  final count = header.count;
  final payloadLength = header.payloadLength;

  if (count == 0) {
    cursor.skip(payloadLength);
    return FourdgsAttributeStream(
      attributeId: attributeId,
      channels: channels,
      count: 0,
      values: Int32List(0),
    );
  }
  if (width != 1 && width != 2 && width != 4) {
    throw FourdgsMalformedFile(
      'attribute $attributeId: bad symbol width $width',
    );
  }
  if (channels == 0) {
    throw FourdgsMalformedFile('attribute $attributeId: zero channels');
  }

  final symbols = mode == modeConst ? channels : count * channels;
  final expected = symbols * width;
  if (expected > maxStreamBytes) {
    throw FourdgsMalformedFile(
      'attribute $attributeId declares $expected bytes, past the $maxStreamBytes cap',
    );
  }
  // The cap above bounds what is *decompressed*; this bounds what is
  // *materialized*, and they are not the same number. A constant-mode stream
  // stores `channels` symbols and repeats them `element_count` times, so a
  // handful of payload bytes can name a four-billion-element array — the cheap
  // half of a decompression bomb, and one the size ceiling alone does not see.
  if (count * channels > maxStreamBytes ~/ 4) {
    throw FourdgsMalformedFile(
      'attribute $attributeId would expand to ${count * channels} values, past the cap',
    );
  }

  final raw = _decompress(cursor.take(payloadLength), codec, expected);
  final sym = _unshuffle(raw, width, symbols);

  final values = Int32List(count * channels);
  if (mode == modeConst) {
    // Exactly `channels` symbols, repeated `count` times.
    for (int c = 0; c < channels; c++) {
      final v = _unzigzag(sym[c]);
      for (int i = 0; i < count; i++) {
        values[i * channels + c] = v;
      }
    }
  } else {
    for (int i = 0; i < symbols; i++) {
      values[i] = _unzigzag(sym[i]);
    }
    if (mode == modeDelta) {
      // Delta runs along element order, so a channel accumulates against the
      // same channel of the previous element.
      for (int i = channels; i < values.length; i++) {
        values[i] += values[i - channels];
      }
    } else if (mode != modeRaw) {
      throw FourdgsMalformedFile(
        'attribute $attributeId: unknown stream mode $mode',
      );
    }
  }
  return FourdgsAttributeStream(
    attributeId: attributeId,
    channels: channels,
    count: count,
    values: values,
  );
}

/// Inflates a stream payload, refusing to materialize more than the stream
/// header declared — a crafted small frame must not expand without bound.
///
/// Defence is in two layers, and the second one is the interesting one:
///
/// 1. The **declared** size is rejected before inflating, by the caller's
///    [maxStreamBytes] check. Cheap, and it closes an honestly-declared bomb.
/// 2. The **actual** inflate writes into a sink that throws the moment it passes
///    the declared size. That closes a *lying* header — one that declares a
///    kilobyte and expands to gigabytes — while it is expanding, not after.
///
/// Layer 2 drives [Inflate] directly rather than going through the packaged
/// zlib decoder, and that is the whole point. `ZLibDecoderWeb.decodeStream`
/// looks like it streams, but internally it runs `Inflate.stream(input)
/// .getBytes()` and hands the finished buffer to its output in one write — so a
/// bounded sink underneath it sees the bomb only once the bomb has already been
/// allocated, on every platform. `Inflate` writes to an output as it decodes,
/// so passing the sink in is what makes the bound real.
///
/// The RFC 1950 wrapper is handled here for the same reason: the format's
/// deflate is a zlib stream, not a bare deflate block, and going direct means
/// stepping over its two-byte header and checking its trailing Adler-32. That
/// checksum is worth the four bytes it costs to read: the container's own CRC
/// covers the index and nothing else, so without it a payload that happens to
/// inflate to the declared length hands back wrong bins with nothing to say so.
Uint8List _decompress(Uint8List body, int codec, int expected) {
  if (codec == codecZstd) {
    // Legal per the specification and appropriate for archival encodes, but it
    // needs a binding this decoder deliberately does not have. Writers default
    // to deflate precisely so that no platform needs one.
    throw const FourdgsUnsupportedCodec(
      'this stream is zstd-coded; re-encode with the default deflate codec',
    );
  }
  if (codec != codecDeflate) {
    throw FourdgsUnsupportedCodec('unknown stream codec $codec');
  }
  if (body.length < 2) {
    throw const FourdgsTruncatedFile(
      'a deflate payload is too short to hold its zlib header',
    );
  }

  // RFC 1950: CMF then FLG. Low four bits of CMF are the method (8 = deflate),
  // (CMF * 256 + FLG) is a multiple of 31, and bit 5 of FLG is a preset
  // dictionary this decoder does not carry.
  final cmf = body[0];
  final flg = body[1];
  if (cmf & 0x0F != 8 || (cmf * 256 + flg) % 31 != 0 || flg & 0x20 != 0) {
    throw const FourdgsMalformedFile(
      'a stream payload is not a well-formed zlib frame',
    );
  }

  final sink = _BoundedSink(expected);
  try {
    Inflate.stream(
      InputMemoryStream(Uint8List.sublistView(body, 2)),
      output: sink,
    );
  } on FourdgsException {
    rethrow; // the sink's own ceiling, which already says what happened
  } catch (error) {
    // A corrupted deflate payload makes the inflater walk off its own tables,
    // and what comes back is a RangeError rather than anything about this
    // format. Translated here so that every way this decoder can reject a file
    // is one exception family — a caller should not have to know which library
    // is underneath in order to catch a bad file.
    throw FourdgsMalformedFile(
      'a stream payload is not decodable deflate ($error)',
    );
  }
  final out = sink.getBytes();
  if (out.length != expected) {
    throw FourdgsTruncatedFile(
      'stream decompressed to ${out.length} bytes, header declared $expected',
    );
  }
  // RFC 1950 closes with a big-endian Adler-32 of the uncompressed data.
  if (body.length < 6) {
    throw const FourdgsTruncatedFile(
      'a deflate payload is too short to hold its zlib trailer',
    );
  }
  final declared =
      (body[body.length - 4] << 24) |
      (body[body.length - 3] << 16) |
      (body[body.length - 2] << 8) |
      body[body.length - 1];
  if (getAdler32(out) != declared) {
    throw const FourdgsMalformedFile(
      'a stream payload failed its zlib checksum',
    );
  }
  return out;
}

/// An inflate target that refuses to grow past what the stream header declared.
///
/// The throw happens inside the inflate loop, so a bomb stops expanding at the
/// ceiling instead of being measured after it has finished.
class _BoundedSink extends OutputMemoryStream {
  _BoundedSink(this._limit);

  final int _limit;

  void _check() {
    if (length > _limit) {
      throw FourdgsMalformedFile(
        'a stream inflated past the $_limit bytes it declared',
      );
    }
  }

  @override
  void writeByte(int value) {
    super.writeByte(value);
    _check();
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    super.writeBytes(bytes, length: length);
    _check();
  }

  @override
  void writeStream(InputStream stream) {
    super.writeStream(stream);
    _check();
  }
}

/// Reverses the byte-plane shuffle: plane `j` holds byte `j` of every symbol,
/// so symbol `i` is `raw[j * n + i] << 8j` summed over `j`.
Uint32List _unshuffle(Uint8List raw, int width, int symbols) {
  final out = Uint32List(symbols);
  if (width == 1) {
    for (int i = 0; i < symbols; i++) {
      out[i] = raw[i];
    }
    return out;
  }
  for (int j = 0; j < width; j++) {
    final base = j * symbols;
    final shift = 8 * j;
    for (int i = 0; i < symbols; i++) {
      out[i] |= raw[base + i] << shift;
    }
  }
  return out;
}

int _unzigzag(int u) => (u >> 1) ^ -(u & 1);

/// CRC-32 (IEEE) over [data], as the Footer's `summary_crc` declares it.
int fourdgsCrc32(Uint8List data) => getCrc32(data);
