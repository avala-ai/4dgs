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

/// A legal file feature that this particular high-level API cannot preserve.
///
/// This is distinct from malformed input: adding support, rather than repairing
/// the file, is what makes the operation possible.
class FourdgsUnsupportedFeature extends FourdgsException {
  const FourdgsUnsupportedFeature(super.message);
}

/// The framing held but the content did not make sense — a required record
/// missing, an attribute absent from a chunk, a field out of range.
class FourdgsMalformedFile extends FourdgsException {
  const FourdgsMalformedFile(super.message, {super.refusalCode});
}

/// The refusal a `window_index` outside the Window Table gets, wherever it is
/// reached from.
///
/// One sentence in one place because there are three reach sites: the
/// `gaussian-birth` chunk decoder, and both grid lookups on the keyframe-delta
/// path. Six SDKs are compared on the identifier, but the person holding the
/// file is looking for a record — and three separately written spellings of one
/// refusal is three chances for one of them to leave the location out, which is
/// how the chunk decoder's came to say only the value and the table size.
///
/// [gaussian] locates the offending record: `"gaussian 5 of the chunk at byte
/// 4096"` on the chunk path, `"gaussian 77"` on the keyframe-delta path, where
/// the stable id is what the file carries and the row is an artefact of
/// composition order. Empty for a caller with no record to blame, which drops
/// the clause rather than printing a dangling `gaussian -1`.
/// A second Header, Quantization or Window Table record in one file.
///
/// These three describe the whole file, and nothing in a `.4dgs` file says
/// which of two copies wins. A reader that keeps the last silently disagrees
/// with one that keeps the first — and both of those readers are in this
/// package: the streamed reader walked every record and kept whichever came
/// last, while the indexed opener parses the front matter and would keep the
/// first. Same bytes, two scenes.
///
/// That is the outcome §5.14 and §5.15.3 already refuse duplicate coordinate
/// frame and sensor names to avoid, and the indexed opener already refuses a
/// second legacy Audio record for. This extends the same rule to the three
/// records that describe the file itself, where the disagreement is widest.
///
/// Refusing costs a producer nothing: no writer here emits two, so a file
/// carrying two is damaged or is courting exactly this ambiguity.
FourdgsMalformedFile duplicateStructuralRecord(String name, int offset) {
  return FourdgsMalformedFile(
    'a second $name record at byte $offset; a file carries exactly one, and '
    'nothing says which of two copies a reader should believe',
  );
}

FourdgsMalformedFile windowIndexOutOfRange(
  int index,
  int tableLength, {
  String gaussian = '',
}) {
  return FourdgsMalformedFile(
    gaussian.isEmpty
        ? 'window index $index is outside the $tableLength-entry window table'
        : '$gaussian names window index $index, which is outside the '
            '$tableLength-entry window table',
    refusalCode: refusalWindowIndexOutOfRange,
  );
}
