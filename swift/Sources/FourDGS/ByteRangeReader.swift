// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Anything that can report its size and read a byte range.
///
/// The SDK depends on this and nothing else — no filesystem, no HTTP, no platform types.
/// Transports are separate, small and swappable, which is what lets the same decoder run
/// on visionOS, on a server, and in a test with a byte array.
public protocol ByteRangeReader {
    /// Total size of the resource in bytes.
    func byteCount() throws -> Int64

    /// Read up to `count` bytes starting at `offset`.
    ///
    /// A short read is not an error here: a truncated file is a legitimate input to the
    /// streaming path, and it is the decoder's job to say which record ran out of bytes.
    /// Returning fewer bytes than asked for is how this protocol reports end of resource.
    mutating func read(offset: Int64, count: Int) throws -> [UInt8]
}

/// A reader over bytes already in memory. The transport tests use.
public struct InMemoryReader: ByteRangeReader, Sendable {
    public let bytes: [UInt8]

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public func byteCount() throws -> Int64 {
        Int64(bytes.count)
    }

    public func read(offset: Int64, count: Int) throws -> [UInt8] {
        guard offset >= 0, count >= 0 else {
            throw FourDGSError.invalidRange(offset: offset, count: count)
        }
        let start = min(Int(clamping: offset), bytes.count)
        let end = min(start + count, bytes.count)
        return Array(bytes[start..<end])
    }
}

#if canImport(Foundation)
    import Foundation

    /// A reader over a file on disk. Seeks and reads only the range asked for, so an
    /// indexed decode of a 4 GB scene touches the index and the chunks it needs.
    public struct FileReader: ByteRangeReader {
        private let handle: FileHandle
        private let size: Int64

        public init(path: String) throws {
            guard let handle = FileHandle(forReadingAtPath: path) else {
                throw FourDGSError.unreadableSource(description: "cannot open \(path) for reading")
            }
            self.handle = handle
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            self.size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }

        public func byteCount() throws -> Int64 {
            size
        }

        public func read(offset: Int64, count: Int) throws -> [UInt8] {
            guard offset >= 0, count >= 0 else {
                throw FourDGSError.invalidRange(offset: offset, count: count)
            }
            try handle.seek(toOffset: UInt64(offset))
            let data = handle.readData(ofLength: count)
            return [UInt8](data)
        }
    }
#endif
