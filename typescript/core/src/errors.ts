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

/** Base class for every error this package raises. */
export class FourdgsError extends Error {
  constructor(message: string) {
    super(message);
    this.name = new.target.name;
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
 *
 * Carries an optional stable `code` naming the failure (e.g. `"forward-reference"`), so a
 * caller — or the conformance suite's refusal expectations — can match the reason a file
 * was refused without parsing the human message.
 */
export class MalformedFile extends FourdgsError {
  readonly code: string;

  constructor(message: string, code = "") {
    super(message);
    this.code = code;
  }
}

/**
 * A legal but unimplemented codec. The file is fine; this build cannot read it.
 *
 * Kept distinct from {@link MalformedFile} because the fix is different: an
 * unrecognized-but-legal value needs a codec, a malformed one needs a new file.
 */
export class UnsupportedCodec extends FourdgsError {}
