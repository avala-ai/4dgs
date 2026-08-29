// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/**
 * Error types.
 *
 * A decoder that refuses a file says which field, which value, and what was expected.
 * These types exist so a caller can tell apart the cases that need different responses:
 * the file is not ours, the file is ours but from the future, the file is ours and
 * broken, and the file is fine but this build cannot read one of its codecs.
 */

/**
 * Every refusal this reader can name (spec: the refusal table).
 *
 * Constants rather than string literals at the raise sites, because these are compared
 * across six implementations: a typo in one is a conformance failure that reads like a
 * decoder bug.
 */
export const Refusal = {
  /** The file does not begin with the 4dgs magic. */
  MagicMismatch: "magic-mismatch",
  /** The magic is ours; the major version is not one this reader implements. */
  UnsupportedMajorVersion: "unsupported-major-version",
  /**
   * The Header names a temporal model this build does not implement — including the
   * empty name, which is a declaration of nothing rather than a default.
   */
  UnknownTemporalModel: "unknown-temporal-model",
  /** The Quantization record names a scheme this build does not implement. */
  UnknownQuantizationScheme: "unknown-quantization-scheme",
  /** The Quantization record declares a finite birth-time grid pitch at or below zero. */
  NonPositiveStepTime: "non-positive-step-time",
  /** A stream declares a codec this build does not implement. */
  UnknownStreamCodec: "unknown-stream-codec",
  /** A gaussian's window index names a row the Window Table does not have. */
  WindowIndexOutOfRange: "window-index-out-of-range",
} as const;

/** One of the identifiers in {@link Refusal}. */
export type RefusalCode = (typeof Refusal)[keyof typeof Refusal];

/** Options every error in this package accepts. */
export interface FourdgsErrorOptions {
  /** The identifier for a refusal the specification names. See {@link Refusal}. */
  readonly refusalCode?: RefusalCode | undefined;
}

/**
 * Base class for every error this package raises.
 *
 * `refusalCode` is an optional **refusal identifier**: a short, stable,
 * language-independent name for the rule the file broke. The message is what a human
 * reads; the identifier is what two implementations in two languages can be compared on,
 * because the error *class* is far too coarse for that — `MalformedFile` covers a dozen
 * distinct faults, and "both decoders threw MalformedFile" is not agreement.
 *
 * It is a property on this class rather than a subclass of it on purpose: an existing
 * `instanceof FourdgsError` — or `instanceof UnsupportedCodec` — keeps meaning exactly
 * what it meant before, so naming a refusal breaks nobody.
 *
 * `undefined` means "a real error the refusal table does not name" — a truncated
 * transport, an encoder bound violation — not "no error".
 */
export class FourdgsError extends Error {
  /** The refusal this is, when the specification names it. */
  readonly refusalCode?: RefusalCode | undefined;

  constructor(message: string, options?: FourdgsErrorOptions) {
    super(message);
    this.name = new.target.name;
    this.refusalCode = options?.refusalCode;
  }
}

/**
 * Not a 4dgs file, or a major version this reader does not implement.
 *
 * Distinct from a malformed file: the fix is a newer reader, not a new file.
 */
export class UnsupportedVersion extends FourdgsError {}

/**
 * The resource ended, or a length ran past the end of its container.
 *
 * Common and often recoverable: records are length-prefixed, so a streamed reader keeps
 * everything complete before the cut.
 */
export class TruncatedFile extends FourdgsError {}

/**
 * A structurally invalid file: a required record missing, a bad index, a value outside
 * its legal range.
 */
export class MalformedFile extends FourdgsError {}

/**
 * A legal but unimplemented codec. The file is fine; this build cannot read it.
 *
 * Kept distinct from {@link MalformedFile} because the fix is different: an
 * unrecognized-but-legal value needs a codec, a malformed one needs a new file.
 */
/**
 * A second Header, Quantization or Window Table record in one file (spec section 4).
 *
 * These three describe the whole file, and nothing in a `.4dgs` file says which of two
 * copies wins. A reader that keeps the last silently disagrees with one that keeps the
 * first — and both of those readers are in this package: the streamed decoder walks
 * every record and kept whichever came last, while the indexed decoder scans the front
 * matter and would keep the first. Same bytes, two scenes.
 *
 * Spelled once rather than at each of the six call sites, for the reason the
 * window-index refusal is spelled once: six spellings is six chances for one of them to
 * leave the offset out.
 */
export function duplicateStructuralRecord(name: string, offset: number): MalformedFile {
  return new MalformedFile(
    `a second ${name} record at byte ${offset}; a file carries exactly one, and ` +
      `nothing says which of two copies a reader should believe`,
  );
}

export class UnsupportedCodec extends FourdgsError {}

/**
 * A legal file whose scale is past a ceiling this reader states in advance.
 *
 * Not a fault in the file: it is what a bounded operation costs. A reader that will not
 * allocate without a limit (AGENTS.md §1) has to declare one, and past it the honest
 * reply is this rather than an allocation the file's own contents chose. The fix is a
 * larger limit, not a new file — which is what separates it from {@link MalformedFile},
 * and why a caller should not tell the user their file is broken.
 *
 * Mirrors `ExceedsReaderLimit` in `python/fourdgs/fourdgs/exceptions.py`.
 */
export class ExceedsReaderLimit extends FourdgsError {}
