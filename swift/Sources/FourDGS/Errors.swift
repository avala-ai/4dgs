// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Why a file was refused.
///
/// This package parses untrusted bytes, so a bare error type is not a diagnosis: every
/// case here names the byte, the record, the value it found and the value it expected.
///
/// The split that matters is between **malformed** and **unsupported**. A malformed file
/// is broken and the fix is to re-encode it; an unsupported one is legal and the fix is a
/// newer reader. Collapsing the two sends people to debug the wrong thing.
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
    case malformed(offset: Int64, record: String, field: String, reason: String)

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
    case unsupportedCodec(offset: Int64, record: String, name: String)

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
    case core(code: Int32, message: String)

    /// Reached a path whose implementation is still the C ABI seam.
    case notImplemented(String)
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
        case .malformed(let offset, let record, let field, let reason):
            return "malformed \(record).\(field) at byte \(offset): \(reason)"
        case .windowIndexOutOfRange(let offset, let index, let tableSize):
            return
                "window index \(index) at byte \(offset) is outside the Window Table, which has \(tableSize) entries"
        case .summaryChecksumMismatch(let offset, let declared, let computed):
            return
                "summary CRC mismatch at byte \(offset): the Footer declares \(declared), the bytes compute \(computed)"
        case .unsupportedCodec(let offset, let record, let name):
            return "unsupported codec \"\(name)\" named by \(record) at byte \(offset); the file is legal, this reader is not new enough"
        case .unsupportedValue(let offset, let record, let field, let value):
            return
                "unsupported \(record).\(field) value \"\(value)\" at byte \(offset); the file is legal, this reader is not new enough"
        case .noChunkIndex:
            return "this file declares no chunk index (Footer.summary_start is 0) and must be read sequentially"
        case .invalidRange(let offset, let count):
            return "invalid range: offset \(offset), count \(count)"
        case .unreadableSource(let description):
            return "unreadable source: \(description)"
        case .core(let code, let message):
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
