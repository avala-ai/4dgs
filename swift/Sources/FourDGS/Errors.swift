// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The specification's name for **which** rule a file broke.
///
/// ``FourDGSError`` says what *kind* of thing went wrong; this says which rule, in the same
/// seven words Python, Rust, TypeScript, C++ and Dart print for the same file. That is the
/// difference between "both decoders refused it" and "both decoders refused it for the same
/// reason" — a reader that rejects a bad-magic file because it mis-parsed the version passes
/// a bare-refusal test and is still wrong.
///
/// The vocabulary is closed and is defined once, in `rust/fourdgs/src/error.rs`.
public enum RefusalCode: String, Sendable, Equatable, CaseIterable {

    /// The file does not begin with the 4dgs magic.
    case magicMismatch = "magic-mismatch"

    /// The magic is ours; the major version is not one this reader implements.
    case unsupportedMajorVersion = "unsupported-major-version"

    /// The Header names a temporal model this build does not implement — including the
    /// empty name.
    case unknownTemporalModel = "unknown-temporal-model"

    /// The Quantization record names a scheme this build does not implement.
    case unknownQuantizationScheme = "unknown-quantization-scheme"

    /// The Quantization record's birth-time grid has no positive spacing.
    case nonPositiveStepTime = "non-positive-step-time"

    /// A stream declares a codec this build does not implement.
    case unknownStreamCodec = "unknown-stream-codec"

    /// A gaussian's `window_index` names a row the Window Table does not have.
    case windowIndexOutOfRange = "window-index-out-of-range"
}

/// Why a file was refused.
///
/// This package parses untrusted bytes, so a bare error type is not a diagnosis: every
/// case here names the byte, the record, the value it found and the value it expected.
///
/// The split that matters is between **malformed** and **unsupported**. A malformed file
/// is broken and the fix is to re-encode it; an unsupported one is legal and the fix is a
/// newer reader. Collapsing the two sends people to debug the wrong thing.
///
/// Three cases carry a ``RefusalCode`` as a trailing associated value. They are the three
/// the C ABI seam builds, and each is many-to-one: ``unsupportedCodec`` alone stands for
/// three different identifiers. That ambiguity is exactly why the core grew
/// `fourdgs_last_refusal_code` instead of three more status codes, and the value is
/// carried rather than recomputed because only the core knows which rule it applied.
///
/// The `= nil` default is a **construction** convenience and nothing more: `.malformed(…)`
/// spelled with the previous four arguments still builds. It does not make the addition
/// source-compatible for consumers, because a default has no effect on a pattern — code
/// that destructures `case .malformed(let offset, let record, let field, let reason)` now
/// fails to compile with "tuple pattern has the wrong length". Adding an associated value
/// to a public case is a breaking change to the API, and this one is taken deliberately:
/// nothing is released, no package registry entry exists, and the alternative — a seventh
/// case, or a parallel error type — would break every exhaustive `switch` instead, which
/// is worse. Anyone destructuring these three cases adds a `_` for the new element.
public enum FourDGSError: Error, Equatable, Sendable {

    // MARK: Malformed — the file is wrong

    /// The 8-byte magic is not `\x894DGS1\r\n`.
    case notFourDGS(offset: Int64, found: [UInt8])

    /// The magic's version byte names a major version this reader does not implement.
    /// A reader that does not implement a version must refuse the file rather than guess.
    case unsupportedMajorVersion(found: UInt8, supported: UInt8)

    /// A record declared more bytes than the resource has left.
    case truncated(offset: Int64, record: String, needed: Int64, available: Int64)

    /// A field held a value the specification does not allow.
    case malformed(offset: Int64, record: String, field: String, reason: String, refusal: RefusalCode? = nil)

    /// A gaussian referenced a window the Window Table does not contain. Not clamped:
    /// clamping substitutes one gaussian's lifetime for another's in a file that is
    /// already corrupt, turning a detectable fault into wrong output.
    case windowIndexOutOfRange(offset: Int64, index: Int, tableSize: Int)

    /// The footer's CRC over the summary region did not match the bytes read.
    case summaryChecksumMismatch(offset: Int64, declared: UInt32, computed: UInt32)

    // MARK: Unsupported — the file is legal, this reader is not new enough

    /// A chunk named a compression codec this reader does not implement. Distinct from a
    /// corrupt chunk: ignoring the codec would decode compressed bytes as attribute
    /// streams, which produces wrong gaussians rather than an error.
    case unsupportedCodec(offset: Int64, record: String, name: String, refusal: RefusalCode? = nil)

    /// A well-known string — profile, quantization scheme, temporal model, interpolation
    /// — that is in the registry's space but not in this reader's.
    case unsupportedValue(offset: Int64, record: String, field: String, value: String)

    // MARK: Structural

    /// An indexed read was asked of a file that declares no index (`summary_start == 0`).
    /// Such a file is valid; it must be read sequentially.
    case noChunkIndex

    /// A range that cannot be read: negative offset or count.
    case invalidRange(offset: Int64, count: Int)

    /// The transport could not be opened or read.
    case unreadableSource(description: String)

    /// The Rust core reported an error this version of the binding has no case for. The
    /// code and message are passed through verbatim rather than flattened, so a core that
    /// grows a new failure mode is still diagnosable from Swift.
    case core(code: Int32, message: String, refusal: RefusalCode? = nil)

    /// Reached a path whose implementation is still the C ABI seam.
    case notImplemented(String)
}

extension FourDGSError {

    /// Which rule this file broke, or `nil` when no rule in the refusal table names it.
    ///
    /// `nil` is an answer, not a gap in the plumbing. A truncated transport, an I/O failure
    /// and a caller's bad range are real errors that the table does not name, and reporting
    /// one of them under a borrowed identifier would be worse than reporting none. The
    /// distinction a caller needs — "no error at all" — is the absence of a thrown error,
    /// not `nil` here.
    ///
    /// Three cases answer from the case alone, because each is one rule and nothing else:
    /// a file whose magic is wrong broke exactly the magic rule. The other three answer
    /// with what they were built carrying, because the same case stands for several rules.
    public var refusalCode: RefusalCode? {
        switch self {
        case .notFourDGS:
            return .magicMismatch
        case .unsupportedMajorVersion:
            return .unsupportedMajorVersion
        case .windowIndexOutOfRange:
            return .windowIndexOutOfRange
        case .malformed(_, _, _, _, let refusal):
            return refusal
        case .unsupportedCodec(_, _, _, let refusal):
            return refusal
        case .core(_, _, let refusal):
            return refusal
        // Listed rather than left to a `default`, so that a case added later has to decide
        // whether it names a refusal instead of silently answering `nil`.
        case .truncated, .summaryChecksumMismatch, .unsupportedValue, .noChunkIndex,
            .invalidRange, .unreadableSource, .notImplemented:
            return nil
        }
    }
}

extension FourDGSError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFourDGS(let offset, let found):
            let hex = found.map(hexByte).joined(separator: " ")
            return "not a 4dgs file: expected magic 89 34 44 47 53 31 0d 0a at byte \(offset), found \(hex)"
        case .unsupportedMajorVersion(let found, let supported):
            return
                "unsupported major version: the magic's version byte is \(found) ('\(Character(UnicodeScalar(found)))'), this reader implements \(supported)"
        case .truncated(let offset, let record, let needed, let available):
            return "truncated \(record) at byte \(offset): needs \(needed) bytes, \(available) remain"
        case .malformed(let offset, let record, let field, let reason, _):
            return "malformed \(record).\(field) at byte \(offset): \(reason)"
        case .windowIndexOutOfRange(let offset, let index, let tableSize):
            return
                "window index \(index) at byte \(offset) is outside the Window Table, which has \(tableSize) entries"
        case .summaryChecksumMismatch(let offset, let declared, let computed):
            return
                "summary CRC mismatch at byte \(offset): the Footer declares \(declared), the bytes compute \(computed)"
        case .unsupportedCodec(let offset, let record, let name, _):
            return
                "unsupported codec \"\(name)\" named by \(record) at byte \(offset); the file is legal, this reader is not new enough"
        case .unsupportedValue(let offset, let record, let field, let value):
            return
                "unsupported \(record).\(field) value \"\(value)\" at byte \(offset); the file is legal, this reader is not new enough"
        case .noChunkIndex:
            return
                "this file declares no chunk index (Footer.summary_start is 0) and must be read sequentially"
        case .invalidRange(let offset, let count):
            return "invalid range: offset \(offset), count \(count)"
        case .unreadableSource(let description):
            return "unreadable source: \(description)"
        case .core(let code, let message, _):
            return "4dgs core error \(code): \(message)"
        case .notImplemented(let what):
            return "\(what) is not implemented yet in the Swift SDK"
        }
    }
}

/// Two lowercase hex digits. Hand-rolled rather than `String(format:)` so that diagnostics
/// do not pull Foundation into a package whose core is meant to have no dependencies.
func hexByte(_ value: UInt8) -> String {
    let digits = Array("0123456789abcdef")
    return String(digits[Int(value >> 4)]) + String(digits[Int(value & 0x0F)])
}
