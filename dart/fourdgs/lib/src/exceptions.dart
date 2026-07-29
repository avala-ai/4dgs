// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Everything this decoder throws, so a caller can catch the whole family.
///
/// It extends [FormatException] because "this resource is not what it claims to
/// be" is exactly what that type means, and callers already written against it
/// keep working.
class FourdgsException extends FormatException {
  const FourdgsException(super.message);

  @override
  String toString() => '4dgs: $message';
}

/// The file ended, or a length pointed past the end, before a structure was
/// complete.
///
/// Records are length-prefixed, so a file truncated mid-write is not garbage —
/// everything complete before the cut is still readable. The streamed reader
/// exploits that; the indexed one cannot, because its index is at the tail.
class FourdgsTruncatedFile extends FourdgsException {
  const FourdgsTruncatedFile(super.message);
}

/// The magic is absent, or names a major version this reader does not implement.
///
/// The specification requires refusal rather than a guess: the version byte
/// gates the whole file, so a reader that pressed on would be interpreting
/// unknown bytes as known ones.
class FourdgsUnsupportedVersion extends FourdgsException {
  const FourdgsUnsupportedVersion(super.message);
}

/// A stream names a codec this build cannot decode.
class FourdgsUnsupportedCodec extends FourdgsException {
  const FourdgsUnsupportedCodec(super.message);
}

/// The framing held but the content did not make sense — a required record
/// missing, an attribute absent from a chunk, a field out of range.
class FourdgsMalformedFile extends FourdgsException {
  const FourdgsMalformedFile(super.message);
}
