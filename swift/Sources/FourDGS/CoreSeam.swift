// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// **The seam.** Every call this package makes into the Rust core goes through this file
/// and no other.
///
/// The Swift SDK is a binding, not a second implementation: there is one decoder in this
/// repository per §"Decoders are fast; the encoder is a reference", and hand-writing a
/// parallel one in Swift would give the format two interpretations to keep in agreement.
/// So everything above this file — the model, the errors, the readers, the §3 arithmetic —
/// is Swift, and everything below it is `rust/fourdgs` reached over its C ABI.
///
/// Today the bodies throw ``FourDGSError/notImplemented(_:)``. Wiring them up means:
///
/// 1. adding a `CFourDGS` system-library target in `Package.swift` whose module map points
///    at `rust/fourdgs/include/fourdgs.h`;
/// 2. replacing the bodies here, and nothing else in the package;
/// 3. building the Rust staticlib in CI before the Swift job.
///
/// ## Ownership at the boundary
///
/// The rule this file will hold to, stated before there is any code to break it:
///
/// - **Buffers the core allocates are copied into Swift storage before the call returns,
///   and freed with the core's own free function in the same scope.** No Swift value ever
///   points into memory the core owns. An `Array` handed back to a caller therefore has no
///   lifetime relationship to the handle it came from, which is what makes the model types
///   honestly `Sendable`.
/// - **Buffers Swift lends to the core are lent for the duration of one call**, via
///   `withUnsafeBufferPointer`, and the core must not retain them. Nothing is passed by
///   escaping pointer.
/// - **Handles are owned by exactly one Swift value** and released in its `deinit`. That
///   makes the owning type a `final class`, not a `struct`, and it is the reason
///   ``StreamedReader`` and ``IndexedReader`` are `struct`s that do *not* hold one today —
///   when a handle appears it goes in a class, so copying a reader cannot double-free.
/// - **Strings cross as UTF-8 byte ranges with an explicit length,** never as
///   NUL-terminated C strings: the format's own `string` type is length-prefixed and may
///   legally contain a NUL.
enum Core {

    /// The front matter plus the offset of the first Chunk record.
    struct OpenedStream {
        var scene: Scene
        var cursor: Int64
    }

    /// Read from the magic up to the first Chunk record.
    static func readFrontMatter<S: ByteRangeReader>(_ source: inout S) throws -> OpenedStream {
        try validateMagic(&source)
        throw FourDGSError.notImplemented("streamed decode")
    }

    /// Read the Footer, then the index and the summary records it points at.
    static func readSummary<S: ByteRangeReader>(_ source: inout S, options: DecodeOptions) throws -> Scene {
        try validateMagic(&source)
        throw FourDGSError.notImplemented("indexed decode")
    }

    /// Decode the chunk at `cursor` and advance it. `nil` once the gaussian data ends.
    static func nextChunk<S: ByteRangeReader>(
        _ source: inout S, cursor: inout Int64, options: DecodeOptions
    ) throws -> DecodedChunk? {
        throw FourDGSError.notImplemented("streamed chunk decode")
    }

    /// Decode one chunk by its index entry, transferring only the ranges it names.
    static func decodeChunk<S: ByteRangeReader>(
        _ source: inout S, entry: ChunkIndexEntry, options: DecodeOptions
    ) throws -> DecodedChunk {
        throw FourDGSError.notImplemented("indexed chunk decode")
    }

    // MARK: - Above the seam

    /// The 8-byte magic, checked on the Swift side before any byte crosses the ABI.
    ///
    /// The core checks it too. Doing it here as well is not redundancy for its own sake: a
    /// binding's job at an FFI boundary is to reject what it can before handing untrusted
    /// input to code that cannot throw, and this is the cheapest possible instance of that
    /// — eight bytes, one comparison, and the file is either ours or it is not.
    static func validateMagic<S: ByteRangeReader>(_ source: inout S) throws {
        let found = try source.read(offset: 0, count: magic.count)
        guard found.count == magic.count else {
            throw FourDGSError.truncated(
                offset: 0, record: "magic", needed: Int64(magic.count), available: Int64(found.count))
        }
        // The version byte is diagnosed separately from the rest, because "a .4dgs from the
        // future" and "not a .4dgs" send a reader to different places.
        if Array(found[0..<5]) == Array(magic[0..<5]), Array(found[6...]) == Array(magic[6...]),
            found[5] != magic[5]
        {
            throw FourDGSError.unsupportedMajorVersion(found: found[5], supported: magic[5])
        }
        guard found == magic else {
            throw FourDGSError.notFourDGS(offset: 0, found: found)
        }
    }

    /// `\x89 4 D G S 1 \r \n`. §4.1.
    static let magic: [UInt8] = [0x89, 0x34, 0x44, 0x47, 0x53, 0x31, 0x0D, 0x0A]

    /// Translate a code and message from the core into a Swift error.
    ///
    /// The mapping is deliberately partial. A code this binding has no case for becomes
    /// ``FourDGSError/core(code:message:)`` with the core's own message passed through
    /// verbatim, so a core that grows a failure mode stays diagnosable from Swift instead
    /// of being flattened into "decode failed".
    static func translate(code: Int32, message: String) -> FourDGSError {
        .core(code: code, message: message)
    }
}
