// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The file does not begin with the 4dgs magic.
const String refusalMagicMismatch = 'magic-mismatch';

/// The magic is ours; the major version is not one this reader implements.
const String refusalUnsupportedMajorVersion = 'unsupported-major-version';

/// The Header names a temporal model this build does not implement — including
/// the empty name, which is a declaration of nothing rather than a default.
const String refusalUnknownTemporalModel = 'unknown-temporal-model';

/// The Quantization record names a scheme this build does not implement.
const String refusalUnknownQuantizationScheme = 'unknown-quantization-scheme';

/// A stream declares a codec this build does not implement.
const String refusalUnknownStreamCodec = 'unknown-stream-codec';

/// A gaussian's window index names a row the Window Table does not have.
const String refusalWindowIndexOutOfRange = 'window-index-out-of-range';

/// Every refusal this reader can name (spec: the refusal table).
///
/// Named constants rather than string literals at the raise sites, because these
/// are compared across six implementations: a typo in one is a conformance
/// failure that reads like a decoder bug. This set exists so a test can assert
/// that a code it saw is one of the six rather than something invented locally.
const Set<String> fourdgsRefusalCodes = <String>{
  refusalMagicMismatch,
  refusalUnsupportedMajorVersion,
  refusalUnknownTemporalModel,
  refusalUnknownQuantizationScheme,
  refusalUnknownStreamCodec,
  refusalWindowIndexOutOfRange,
};

/// Everything this decoder throws, so a caller can catch the whole family.
///
/// It extends [FormatException] because "this resource is not what it claims to
/// be" is exactly what that type means, and callers already written against it
/// keep working.
class FourdgsException extends FormatException {
  const FourdgsException(super.message, {this.refusalCode});

  /// The refusal this is, when the specification names it, and `null`
  /// otherwise.
  ///
  /// A short, stable, language-independent name for the rule the file broke.
  /// [message] is what a human reads; this is what two implementations in two
  /// languages can be compared on, because the exception *class* is far too
  /// coarse for that — [FourdgsUnsupportedCodec] covers an unknown temporal
  /// model, an unknown quantization scheme and an unknown stream codec alike,
  /// and "both decoders threw [FourdgsUnsupportedCodec]" is not agreement.
  ///
  /// `null` means "a real error the refusal table does not name" — a truncated
  /// transport, a chunk whose declared size exceeds this build's ceiling — not
  /// "no error". The vocabulary is [fourdgsRefusalCodes].
  final String? refusalCode;

  @override
  String toString() => '4dgs: $message';
}

/// The file ended, or a length pointed past the end, before a structure was
/// complete.
///
/// Records are length-prefixed, so a file truncated mid-write is not garbage —
/// everything complete before the cut is still readable. The streamed reader
/// exploits that; the indexed one cannot, because its index is at the tail.
///
/// Alone among the four it takes no refusal code, and that is the point: a cut
/// file is recoverable rather than refusable, so the refusal table has no name
/// for it and this constructor offers nowhere to put one.
class FourdgsTruncatedFile extends FourdgsException {
  const FourdgsTruncatedFile(super.message);
}

/// The magic is absent, or names a major version this reader does not implement.
///
/// The specification requires refusal rather than a guess: the version byte
/// gates the whole file, so a reader that pressed on would be interpreting
/// unknown bytes as known ones.
class FourdgsUnsupportedVersion extends FourdgsException {
  const FourdgsUnsupportedVersion(super.message, {super.refusalCode});
}

/// A stream names a codec this build cannot decode.
class FourdgsUnsupportedCodec extends FourdgsException {
  const FourdgsUnsupportedCodec(super.message, {super.refusalCode});
}

/// The framing held but the content did not make sense — a required record
/// missing, an attribute absent from a chunk, a field out of range.
class FourdgsMalformedFile extends FourdgsException {
  const FourdgsMalformedFile(super.message, {super.refusalCode});
}
