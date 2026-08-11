// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Bounded structural validation aligned with the Python reference validator.
///
/// Swift leaves full record parsing to the core binding. This layer checks framing, indexed
/// metadata, summary structure, and every physical state stream without buffering whole records.

import FourDGS
import CFourDGS
import Foundation

func readU16(_ bytes: [UInt8], at: UInt64) -> UInt16? {
    guard at <= UInt64(bytes.count), UInt64(bytes.count) - at >= 2 else { return nil }
    let start = Int(at)
    return UInt16(bytes[start]) | (UInt16(bytes[start + 1]) << 8)
}

public enum Severity: Int, Comparable {
    case note
    case warning
    case error

    public var name: String {
        switch self {
        case .note: return "note"
        case .warning: return "warning"
        case .error: return "error"
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A diagnostic and, when the SDK named it, its refusal identifier and byte.
public struct Finding {
    public let severity: Severity
    public let message: String
    public let refusal: Named?
}

public struct Report {
    public var findings: [Finding] = []
    public var complete = true

    public var ok: Bool { complete && !findings.contains { $0.severity == .error } }
    public var worst: Severity? { findings.map(\.severity).max() }

    mutating func push(_ severity: Severity, _ message: String, _ refusal: Named?) {
        findings.append(Finding(severity: severity, message: message, refusal: refusal))
    }

    mutating func error(_ message: String) { push(.error, message, nil) }
    mutating func warn(_ message: String) { push(.warning, message, nil) }
    mutating func note(_ message: String) { push(.note, message, nil) }
    mutating func incomplete(_ message: String) {
        complete = false
        warn(message)
    }

    /// Preserve the shared diagnostic sentence while attaching Swift's placed refusal.
    mutating func refused(_ prefix: String, _ error: FourDGSError, _ walk: Walk?, _ site: Site?) {
        push(.error, prefix + sentence(error), describe(error, walk: walk, site: site))
    }
}

private struct SourceSlice {
    let offset: UInt64
    let length: UInt64
    let literal: [UInt8]?
    let reader: ToolReader?

    init(offset: UInt64, length: UInt64) {
        self.offset = offset
        self.length = length
        self.literal = nil
        self.reader = nil
    }

    init(reader: ToolReader, offset: UInt64, length: UInt64) {
        self.offset = offset
        self.length = length
        self.literal = nil
        self.reader = reader
    }

    init(literal: [UInt8]) {
        self.offset = 0
        self.length = UInt64(literal.count)
        self.literal = literal
        self.reader = nil
    }
}

/// A source-backed concatenation; validation never materializes a physical state record.
private struct SlicedReader: ByteRangeReader {
    let source: ToolReader
    let slices: [SourceSlice]
    let count: UInt64

    init(source: ToolReader, slices: [SourceSlice]) {
        self.source = source
        self.slices = slices
        self.count = slices.reduce(0) { partial, slice in
            let (sum, overflow) = partial.addingReportingOverflow(slice.length)
            return overflow ? UInt64.max : sum
        }
    }

    func byteCount() throws -> Int64 {
        guard let count = Int64(exactly: count) else {
            throw FourDGSError.invalidRange(offset: Int64.max, count: 0)
        }
        return count
    }

    func read(offset: Int64, count wanted: Int) throws -> [UInt8] {
        guard offset >= 0, wanted >= 0 else {
            throw FourDGSError.invalidRange(offset: offset, count: wanted)
        }
        var logical = UInt64(offset)
        guard logical < count, wanted > 0 else { return [] }
        var remaining = min(UInt64(wanted), count - logical)
        var out: [UInt8] = []
        out.reserveCapacity(Int(remaining))
        var sliceStart: UInt64 = 0
        for slice in slices {
            let sliceEnd = sliceStart + slice.length
            defer { sliceStart = sliceEnd }
            guard logical < sliceEnd else { continue }
            let within = logical > sliceStart ? logical - sliceStart : 0
            let take = min(remaining, slice.length - within)
            let bytes: [UInt8]
            if let literal = slice.literal {
                let start = Int(within)
                bytes = Array(literal[start..<(start + Int(take))])
            } else {
                guard let readOffset = Int64(exactly: slice.offset + within) else {
                    throw FourDGSError.invalidRange(offset: Int64.max, count: Int(take))
                }
                bytes = try (slice.reader ?? source).read(offset: readOffset, count: Int(take))
            }
            out.append(contentsOf: bytes)
            logical += UInt64(bytes.count)
            remaining -= UInt64(bytes.count)
            if UInt64(bytes.count) != take || remaining == 0 { break }
        }
        return out
    }
}

struct ChunkFields {
    let opcode: UInt8
    let t0: Double
    let t1: Double
    let level: UInt32
    let count: UInt32
    let deltaMode: UInt8
    let referenceOffset: UInt64
    let keyframeOffset: UInt64
    let depth: UInt16
}

private struct PhysicalValidation {
    var fields: [UInt64: ChunkFields] = [:]
    var gaussianCount: UInt64 = 0
    var indexSafe = true
    var chunkRefused = false
}

private func chunkFields(_ source: ToolReader, _ frame: Frame) throws -> ChunkFields? {
    let fixed: UInt64 = frame.opcode == Opcode.deltaChunk ? 39 : 24
    guard frame.length >= fixed else { return nil }
    let bytes = try source.exactly(
        offset: frame.offset + recordHeaderSize, count: Int(fixed), record: opcodeName(frame.opcode))
    guard let t0 = readF64(bytes, at: 0), let t1 = readF64(bytes, at: 8),
        let level = readU32(bytes, at: 16)
    else { return nil }
    if frame.opcode == Opcode.chunk {
        guard let count = readU32(bytes, at: 20) else { return nil }
        return ChunkFields(
            opcode: frame.opcode, t0: t0, t1: t1, level: level, count: count, deltaMode: 0,
            referenceOffset: 0, keyframeOffset: frame.offset, depth: 0)
    }
    guard let referenceOffset = readU64(bytes, at: 21),
        let keyframeOffset = readU64(bytes, at: 29), let depth = readU16(bytes, at: 37)
    else { return nil }
    return ChunkFields(
        opcode: frame.opcode, t0: t0, t1: t1, level: level, count: 0,
        deltaMode: bytes[20],
        referenceOffset: referenceOffset, keyframeOffset: keyframeOffset, depth: depth)
}

private func frontMatterSlices(
    header: Frame, quantization: Frame, windowTable: Frame?, temporalModelOffset: UInt64? = nil
) -> [SourceSlice] {
    var slices = [
        SourceSlice(offset: 0, length: UInt64(magic.count))
    ]
    if let model = temporalModelOffset {
        let after = model + UInt64("gaussian-birth".utf8.count)
        slices += [
            SourceSlice(offset: header.offset, length: model - header.offset),
            SourceSlice(literal: Array("gaussian-birth".utf8)),
            SourceSlice(offset: after, length: header.offset + header.total - after),
        ]
    } else {
        slices.append(SourceSlice(offset: header.offset, length: header.total))
    }
    slices.append(SourceSlice(offset: quantization.offset, length: quantization.total))
    if let windowTable {
        slices.append(SourceSlice(offset: windowTable.offset, length: windowTable.total))
    }
    return slices
}

private func singleChunkReader(
    _ source: ToolReader, header: Frame, quantization: Frame, windowTable: Frame?, chunk: Frame,
    temporalModelOffset: UInt64? = nil, bands: [Frame] = []
) -> SlicedReader {
    var slices = frontMatterSlices(
        header: header, quantization: quantization, windowTable: windowTable,
        temporalModelOffset: temporalModelOffset)
    slices.append(SourceSlice(offset: chunk.offset, length: chunk.total))
    for band in bands { slices.append(SourceSlice(offset: band.offset, length: band.total)) }
    return SlicedReader(source: source, slices: slices)
}

struct DeltaGroup {
    let name: String
    let count: UInt32
    let source: ToolReader
    let offset: UInt64
    let length: UInt64
}

private func malformedDelta(_ frame: Frame, _ reason: String) -> FourDGSError {
    .malformed(
        offset: Int64(clamping: frame.offset), record: "DeltaChunk", field: "groups",
        reason: reason)
}

private func malformedStateStreams(_ frame: Frame, _ reason: String) -> FourDGSError {
    if frame.opcode == Opcode.deltaChunk { return malformedDelta(frame, reason) }
    return .malformed(
        offset: Int64(clamping: frame.offset), record: opcodeName(frame.opcode), field: "streams",
        reason: reason)
}

private final class TemporaryFileReader: ByteRangeReader {
    private let url: URL
    private let handle: FileHandle
    private let count: Int64

    init(url: URL, count: UInt64) throws {
        guard let signedCount = Int64(exactly: count) else {
            throw FourDGSError.invalidRange(offset: Int64.max, count: 0)
        }
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw FourDGSError.unreadableSource(
                description: "cannot reopen temporary inflated state")
        }
        self.url = url
        self.handle = handle
        self.count = signedCount
    }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    func byteCount() throws -> Int64 { count }

    func read(offset: Int64, count: Int) throws -> [UInt8] {
        guard offset >= 0, count >= 0 else {
            throw FourDGSError.invalidRange(offset: offset, count: count)
        }
        try handle.seek(toOffset: UInt64(offset))
        return [UInt8](handle.readData(ofLength: count))
    }
}

private func inflatedReader(
    _ source: ToolReader, offset: UInt64, length: UInt64, expected: UInt64, frame: Frame
) throws -> ToolReader {
    var stream = z_stream()
    let initialized = inflateInit_(&stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
    guard initialized == Z_OK else {
        throw malformedStateStreams(
            frame, "deflate could not initialize (zlib status \(initialized))")
    }
    defer { inflateEnd(&stream) }

    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "4dgs-validate-\(UUID().uuidString).inflate")
    guard FileManager.default.createFile(atPath: url.path, contents: nil),
        let outputHandle = FileHandle(forWritingAtPath: url.path)
    else {
        throw FourDGSError.unreadableSource(
            description: "cannot create temporary storage for inflated state")
    }
    var keepFile = false
    defer {
        try? outputHandle.close()
        if !keepFile { try? FileManager.default.removeItem(at: url) }
    }

    let blockSize = 64 * 1024
    var output = [UInt8](repeating: 0, count: blockSize)
    var status = Int32(Z_OK)
    var inputAt: UInt64 = 0
    var producedTotal: UInt64 = 0
    while inputAt < length, status != Z_STREAM_END {
        let inputCount = Int(min(UInt64(blockSize), length - inputAt))
        let input = try source.exactly(
            offset: offset + inputAt, count: inputCount, record: "compressed state records")
        try input.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer(
                mutating: bytes.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(inputCount)
            repeat {
                let produced = output.withUnsafeMutableBytes { destination in
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(blockSize)
                    status = CFourDGS.inflate(&stream, Z_NO_FLUSH)
                    return blockSize - Int(stream.avail_out)
                }
                let (newTotal, overflow) = producedTotal.addingReportingOverflow(UInt64(produced))
                guard !overflow, newTotal <= expected else {
                    throw malformedStateStreams(
                        frame, "deflate expands past the declared \(expected) bytes")
                }
                if produced > 0 {
                    try outputHandle.write(contentsOf: Data(output[..<produced]))
                    producedTotal = newTotal
                }
                guard status == Z_OK || status == Z_STREAM_END else {
                    throw malformedStateStreams(
                        frame, "deflate could not be decoded (zlib status \(status))")
                }
                if status == Z_OK, produced == 0, stream.avail_in == 0 { break }
            } while stream.avail_in > 0 && status != Z_STREAM_END
            if status == Z_STREAM_END, stream.avail_in != 0 {
                throw malformedStateStreams(frame, "bytes remain after the deflate stream")
            }
        }
        inputAt += UInt64(inputCount)
    }
    guard status == Z_STREAM_END else {
        throw malformedStateStreams(
            frame, "deflate ended after \(producedTotal) of \(expected) bytes")
    }
    guard inputAt == length else {
        throw malformedStateStreams(frame, "bytes remain after the deflate stream")
    }
    guard producedTotal == expected else {
        throw malformedStateStreams(
            frame, "deflate produced \(producedTotal) of the declared \(expected) bytes")
    }
    try outputHandle.close()
    let reader = try ToolReader(TemporaryFileReader(url: url, count: producedTotal))
    keepFile = true
    return reader
}

func deltaGroups(_ source: ToolReader, _ frame: Frame) throws -> [DeltaGroup] {
    let content = frame.offset + recordHeaderSize
    let countsAt: UInt64 = 39
    let compressionLengthAt: UInt64 = 51
    guard frame.length >= compressionLengthAt + 4 else {
        throw malformedDelta(frame, "the fixed fields and compression length do not fit")
    }
    let counts = try source.exactly(
        offset: content + countsAt, count: 12, record: "DeltaChunk group counts")
    let declaredCounts: [UInt32] = [
        readU32(counts, at: 0) ?? UInt32(0), readU32(counts, at: 4) ?? UInt32(0),
        readU32(counts, at: 8) ?? UInt32(0),
    ]
    let compressionField = try source.exactly(
        offset: content + compressionLengthAt, count: 4,
        record: "DeltaChunk compression length")
    let compressionLength = UInt64(readU32(compressionField, at: 0) ?? 0)
    var relative = compressionLengthAt + 4
    guard compressionLength <= frame.length - relative else {
        throw malformedDelta(frame, "compression string runs past the record")
    }
    guard let compressionCount = Int(exactly: compressionLength) else {
        throw malformedDelta(frame, "compression string is larger than this platform can address")
    }
    let compressionBytes = try source.exactly(
        offset: content + relative, count: compressionCount, record: "DeltaChunk compression")
    guard let compression = String(bytes: compressionBytes, encoding: .utf8) else {
        throw malformedDelta(frame, "compression is not UTF-8")
    }
    relative += compressionLength
    guard relative <= frame.length, frame.length - relative >= 16 else {
        throw malformedDelta(frame, "records length does not fit after the compression string")
    }
    let lengths = try source.exactly(
        offset: content + relative, count: 16, record: "DeltaChunk records length")
    let uncompressed = readU64(lengths, at: 0) ?? 0
    let recordsLength = readU64(lengths, at: 8) ?? 0
    relative += 16
    guard recordsLength <= frame.length - relative else {
        throw malformedDelta(frame, "records blob runs past the record")
    }
    guard relative + recordsLength == frame.length else {
        throw malformedDelta(frame, "bytes remain after the records blob")
    }

    let recordsSource: ToolReader
    let recordsStart: UInt64
    let recordsEnd: UInt64
    if compression.isEmpty {
        guard uncompressed == recordsLength else {
            throw malformedStateStreams(
                frame,
                "uncompressed_size is \(uncompressed), but the records blob is \(recordsLength) bytes")
        }
        recordsSource = source
        recordsStart = content + relative
        recordsEnd = recordsStart + recordsLength
    } else {
        guard compression == "deflate" else {
            throw FourDGSError.unsupportedCodec(
                offset: Int64(clamping: content + compressionLengthAt + 4), record: "DeltaChunk",
                name: compression, refusal: .unknownStreamCodec)
        }
        recordsSource = try inflatedReader(
            source, offset: content + relative, length: recordsLength, expected: uncompressed,
            frame: frame)
        recordsStart = 0
        recordsEnd = uncompressed
    }
    var at = recordsStart
    let names = ["update", "birth", "death"]
    var groups: [DeltaGroup] = []
    for i in 0..<3 {
        guard at <= recordsEnd, recordsEnd - at >= 8 else {
            throw malformedDelta(frame, "the \(names[i]) group length is missing")
        }
        let field = try recordsSource.exactly(
            offset: at, count: 8, record: "DeltaChunk \(names[i]) length")
        let length = readU64(field, at: 0) ?? 0
        at += 8
        guard length <= recordsEnd - at else {
            throw malformedDelta(frame, "the \(names[i]) group runs past the records blob")
        }
        groups.append(
            DeltaGroup(
                name: names[i], count: declaredCounts[i], source: recordsSource, offset: at,
                length: length))
        at += length
    }
    guard at == recordsEnd else {
        throw malformedDelta(frame, "bytes remain after the death group")
    }
    return groups
}

private func keyframeGroup(_ source: ToolReader, _ frame: Frame) throws -> DeltaGroup {
    let content = frame.offset + recordHeaderSize
    let compressionLengthAt: UInt64 = 24
    guard frame.length >= compressionLengthAt + 4,
        let fields = try chunkFields(source, frame)
    else {
        throw malformedStateStreams(frame, "the fixed fields and compression length do not fit")
    }
    let compressionField = try source.exactly(
        offset: content + compressionLengthAt, count: 4, record: "Chunk compression length")
    let compressionLength = UInt64(readU32(compressionField, at: 0) ?? 0)
    var relative = compressionLengthAt + 4
    guard compressionLength <= frame.length - relative,
        let compressionCount = Int(exactly: compressionLength)
    else {
        throw malformedStateStreams(frame, "compression string runs past the record")
    }
    let compressionBytes = try source.exactly(
        offset: content + relative, count: compressionCount, record: "Chunk compression")
    guard let compression = String(bytes: compressionBytes, encoding: .utf8) else {
        throw malformedStateStreams(frame, "compression is not UTF-8")
    }
    relative += compressionLength
    guard relative <= frame.length, frame.length - relative >= 16 else {
        throw malformedStateStreams(frame, "stream length does not fit after compression")
    }
    let lengths = try source.exactly(
        offset: content + relative, count: 16, record: "Chunk stream length")
    let uncompressed = readU64(lengths, at: 0) ?? 0
    let streamLength = readU64(lengths, at: 8) ?? 0
    relative += 16
    guard streamLength <= frame.length - relative, relative + streamLength == frame.length else {
        throw malformedStateStreams(frame, "stream blob does not occupy the rest of the record")
    }

    if compression.isEmpty {
        guard uncompressed == streamLength else {
            throw malformedStateStreams(
                frame,
                "uncompressed_size is \(uncompressed), but the stream blob is \(streamLength) bytes")
        }
        return DeltaGroup(
            name: "keyframe", count: fields.count, source: source,
            offset: content + relative, length: streamLength)
    }
    guard compression == "deflate" else {
        throw FourDGSError.unsupportedCodec(
            offset: Int64(clamping: content + compressionLengthAt + 4), record: "Chunk",
            name: compression, refusal: .unknownStreamCodec)
    }
    let records = try inflatedReader(
        source, offset: content + relative, length: streamLength, expected: uncompressed,
        frame: frame)
    return DeltaGroup(
        name: "keyframe", count: fields.count, source: records, offset: 0,
        length: uncompressed)
}

private let requiredGroupAttributes: Set<UInt8> = Set(0...10)
private let invariantUpdateAttributes: Set<UInt8> = [8, 9, 10]

private func validateGroupHeaders(_ frame: Frame, _ group: DeltaGroup) throws {
    if group.length == 0 {
        guard group.count == 0 else {
            throw malformedStateStreams(
                frame, "the \(group.name) group declares \(group.count) rows but has no streams")
        }
        return
    }
    var relative: UInt64 = 0
    var attributes: Set<UInt8> = []
    while relative < group.length {
        guard group.length - relative >= 17 else {
            throw malformedStateStreams(
                frame, "the \(group.name) group ends inside a stream header")
        }
        let header = try group.source.exactly(
            offset: group.offset + relative, count: 17,
            record: "\(opcodeName(frame.opcode)) \(group.name) stream")
        let attribute = header[0]
        guard attributes.insert(attribute).inserted else {
            throw malformedStateStreams(
                frame, "the \(group.name) group carries attribute \(attribute) twice")
        }
        let count = readU32(header, at: 5) ?? 0
        guard count == group.count else {
            throw malformedStateStreams(
                frame,
                "the \(group.name) group declares \(group.count) rows, but attribute "
                    + "\(attribute) carries \(count)")
        }
        let payload = readU64(header, at: 9) ?? 0
        relative += 17
        guard payload <= group.length - relative else {
            throw malformedStateStreams(
                frame, "attribute \(attribute) in the \(group.name) group runs past the group")
        }
        relative += payload
    }
    guard attributes.contains(13) else {
        throw malformedStateStreams(
            frame, "the \(group.name) group carries no gaussian_id stream")
    }
    if group.name == "birth" || group.name == "keyframe" {
        let missing = requiredGroupAttributes.subtracting(attributes).sorted()
        guard missing.isEmpty else {
            throw malformedStateStreams(
                frame, "the \(group.name) group is missing required attributes \(missing)")
        }
    } else if group.name == "update" {
        let forbidden = invariantUpdateAttributes.intersection(attributes).sorted()
        guard forbidden.isEmpty else {
            throw malformedStateStreams(
                frame, "the update group carries lifetime-invariant attributes \(forbidden)")
        }
    } else {
        let surplus = attributes.subtracting([13]).sorted()
        guard surplus.isEmpty else {
            throw malformedStateStreams(
                frame, "the death group carries non-identity attributes \(surplus)")
        }
    }
}

private func littleU32Bytes(_ value: UInt32) -> [UInt8] {
    (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
}

private func littleU64Bytes(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
}

private func syntheticChunkPrefix(
    t0: Double, t1: Double, level: UInt32, count: UInt32, streams: UInt64
) -> [UInt8] {
    var body: [UInt8] = []
    body += littleU64Bytes(t0.bitPattern)
    body += littleU64Bytes(t1.bitPattern)
    body += littleU32Bytes(level)
    body += littleU32Bytes(count)
    body += littleU32Bytes(0)  // empty chunk-level compression string
    body += littleU64Bytes(streams)
    body += littleU64Bytes(streams)
    return [Opcode.chunk] + littleU64Bytes(UInt64(body.count) + streams) + body
}

private func deltaGroupReader(
    _ source: ToolReader, header: Frame, quantization: Frame, windowTable: Frame?,
    temporalModelOffset: UInt64, fields: ChunkFields, group: DeltaGroup, bands: [Frame] = []
) throws -> SlicedReader {
    var slices = frontMatterSlices(
        header: header, quantization: quantization, windowTable: windowTable,
        temporalModelOffset: temporalModelOffset)
    slices.append(
        SourceSlice(
            literal: syntheticChunkPrefix(
                t0: fields.t0, t1: fields.t1, level: fields.level, count: group.count,
                streams: group.length)))
    if group.source === source {
        slices.append(SourceSlice(offset: group.offset, length: group.length))
    } else {
        slices.append(
            SourceSlice(reader: group.source, offset: group.offset, length: group.length))
    }
    for band in bands { slices.append(SourceSlice(offset: band.offset, length: band.total)) }
    return SlicedReader(source: source, slices: slices)
}

private func isExpectedPartialGroupError(_ error: FourDGSError, group: DeltaGroup) -> Bool {
    group.name != "birth" && sentence(error).contains("chunk is missing required attributes")
}

private func validatePhysicalRecords(
    _ source: ToolReader, _ walked: Walk, index: [IndexEntry], keyframeDelta: Bool,
    temporalModelOffset: UInt64?, durationSec: Double?, shDegree: UInt8?,
    summary: SummaryDeclaration?, indexBoundsSafe: Bool,
    report: inout Report
) -> PhysicalValidation {
    var result = PhysicalValidation(indexSafe: indexBoundsSafe)
    var scanReport = Report()
    var byOffset: [UInt64: [Int]] = [:]
    for (i, entry) in index.enumerated() { byOffset[entry.offset, default: []].append(i) }
    var seenEntries: Set<Int> = []
    var bandsByOffset: [UInt64: [(token: Int, entry: Int, band: UInt8, length: UInt64)]] = [:]
    var bandToken = 0
    for (i, entry) in index.enumerated() {
        for band in entry.bands {
            bandsByOffset[band.offset, default: []].append(
                (token: bandToken, entry: i, band: band.band, length: band.length))
            bandToken += 1
        }
    }
    var seenBands: Set<Int> = []
    var currentState: Frame?
    var currentStateFields: ChunkFields?
    var currentBands: [Frame] = []
    var currentBandNumbers: Set<UInt8> = []

    var header: Frame?
    var quantization: Frame?
    var windowTable: Frame?
    var firstStateError: (FourDGSError, Site)?
    var summaryStartsOnBoundary = summary?.start == summary?.end
    var summaryStructureReported = false
    var previousPhysicalInterval: ChunkFields?
    var physicalIntervalCount = 0

    func finishGaussianBirthBands() {
        guard !keyframeDelta, let state = currentState,
            let fields = currentStateFields, fields.opcode == Opcode.chunk,
            let shDegree
        else { return }
        let expected: Set<UInt8> =
            fields.count == 0 || shDegree == 0 ? [] : Set(1...shDegree)
        guard currentBandNumbers != expected else { return }
        let missing = expected.subtracting(currentBandNumbers).sorted()
        let extra = currentBandNumbers.subtracting(expected).sorted()
        var details: [String] = []
        if !missing.isEmpty { details.append("missing bands \(missing)") }
        if !extra.isEmpty { details.append("unexpected bands \(extra)") }
        scanReport.error(
            "the Chunk at byte \(state.offset) declares \(fields.count) gaussians and Header "
                + "sh_degree \(shDegree), but its physical SH Band Streams have "
                + details.joined(separator: " and "))
    }

    func physicalBandSite(_ frame: Frame) -> Site {
        guard let address = bandsByOffset[frame.offset]?.first else {
            return Site(
                offset: frame.offset, what: "the physical SH Band Stream at byte \(frame.offset)")
        }
        return Site(
            offset: frame.offset,
            what:
                "the SH Band Stream for band \(address.band) of the Chunk at index entry "
                + "\(address.entry)")
    }

    do {
        _ = try walk(
            source, retaining: { _ in false },
            visit: { frame, intact in
                guard intact else { return }

                switch frame.opcode {
                case Opcode.header: if header == nil { header = frame }
                case Opcode.quantization: if quantization == nil { quantization = frame }
                case Opcode.windowTable: if windowTable == nil { windowTable = frame }
                default: break
                }

                if let summary, summary.start <= summary.end {
                    let frameEnd = frame.offset + frame.total
                    if frame.offset == summary.start {
                        summaryStartsOnBoundary = true
                        if frame.opcode != Opcode.chunkIndex && !summaryStructureReported {
                            scanReport.error(
                                "the Footer's summary_start \(summary.start) names "
                                    + "\(opcodeName(frame.opcode)); expected the first ChunkIndex")
                            summaryStructureReported = true
                        }
                    }
                    if !summaryStructureReported && frame.offset < summary.start
                        && frameEnd > summary.start
                    {
                        scanReport.error(
                            "the Footer's summary starts at byte \(summary.start), inside the "
                                + "\(opcodeName(frame.opcode)) record at byte \(frame.offset)")
                        summaryStructureReported = true
                    }
                    if frame.offset >= summary.start && frame.offset < summary.end {
                        let allowed =
                            frame.opcode == Opcode.chunkIndex || frame.opcode == Opcode.statistics
                            || frame.opcode == Opcode.summaryOffset
                        if !summaryStructureReported && (!allowed || frameEnd > summary.end) {
                            if !allowed {
                                scanReport.error(
                                    "the Footer's summary contains \(opcodeName(frame.opcode)) at "
                                        + "byte \(frame.offset); expected only ChunkIndex, "
                                        + "Statistics, or SummaryOffset records")
                            } else {
                                scanReport.error(
                                    "the \(opcodeName(frame.opcode)) record at byte \(frame.offset) "
                                        + "extends past the Footer's summary range")
                            }
                            summaryStructureReported = true
                        }
                    }
                }

                if frame.opcode == Opcode.shBandStream {
                    var physicalBand: UInt8?
                    do {
                        guard frame.length > 0 else {
                            throw FourDGSError.malformed(
                                offset: Int64(clamping: frame.offset), record: "SH Band Stream",
                                field: "band", reason: "the record is empty; expected band 1, 2, or 3")
                        }
                        let band = try source.exactly(
                            offset: frame.offset + recordHeaderSize, count: 1,
                            record: "SH Band Stream band")[0]
                        guard (1...3).contains(band) else {
                            throw FourDGSError.malformed(
                                offset: Int64(clamping: frame.offset + recordHeaderSize),
                                record: "SH Band Stream", field: "band",
                                reason: "the record names band \(band); expected 1, 2, or 3")
                        }
                        physicalBand = band
                        guard currentBandNumbers.insert(band).inserted else {
                            throw FourDGSError.malformed(
                                offset: Int64(clamping: frame.offset + recordHeaderSize),
                                record: "SH Band Stream", field: "band",
                                reason: "band \(band) appears twice after the same state record")
                        }
                        currentBands.append(frame)
                    } catch {
                        let stateError = asFourDGS(error)
                        if firstStateError == nil
                            || (firstStateError?.0.refusalCode == nil
                                && stateError.refusalCode != nil)
                        {
                            firstStateError = (stateError, physicalBandSite(frame))
                        }
                    }
                    for address in bandsByOffset[frame.offset] ?? [] {
                        seenBands.insert(address.token)
                        if currentState?.offset != index[address.entry].offset {
                            let physical = currentState.map { String($0.offset) } ?? "no state"
                            scanReport.error(
                                "band \(address.band) of chunk index entry \(address.entry) points "
                                    + "at the SH Band Stream at byte \(frame.offset), but that "
                                    + "stream physically follows \(physical); expected Chunk or "
                                    + "DeltaChunk at byte \(index[address.entry].offset)")
                            result.indexSafe = false
                        }
                        if address.length != frame.total {
                            scanReport.error(
                                "chunk index entry \(address.entry) declares \(address.length) "
                                    + "bytes for the SH Band Stream at byte \(frame.offset); its "
                                    + "framed length is \(frame.total) bytes")
                            result.indexSafe = false
                        }
                        if let physicalBand, physicalBand != address.band {
                            scanReport.error(
                                "chunk index entry \(address.entry) names band "
                                    + "\(address.band), but the SH Band Stream at byte "
                                    + "\(frame.offset) names band \(physicalBand)")
                            result.indexSafe = false
                        }
                    }
                    do {
                        guard let state = currentState else {
                            throw FourDGSError.malformed(
                                offset: Int64(clamping: frame.offset), record: "SH Band Stream",
                                field: "placement", reason: "no Chunk or DeltaChunk precedes it")
                        }
                        guard let header, let quantization else { return }
                        if keyframeDelta {
                            guard let temporalModelOffset else { return }
                            if state.opcode == Opcode.chunk {
                                _ = try SceneReader(
                                    singleChunkReader(
                                        source, header: header, quantization: quantization,
                                        windowTable: windowTable, chunk: state,
                                        temporalModelOffset: temporalModelOffset,
                                        bands: currentBands),
                                    path: .streamed)
                            } else if let fields = try chunkFields(source, state),
                                let birth = try deltaGroups(source, state).first(where: {
                                    $0.name == "birth"
                                })
                            {
                                try validateGroupHeaders(state, birth)
                                _ = try SceneReader(
                                    deltaGroupReader(
                                        source, header: header, quantization: quantization,
                                        windowTable: windowTable,
                                        temporalModelOffset: temporalModelOffset, fields: fields,
                                        group: birth, bands: currentBands),
                                    path: .streamed)
                            }
                        } else if state.opcode == Opcode.chunk {
                            _ = try SceneReader(
                                singleChunkReader(
                                    source, header: header, quantization: quantization,
                                    windowTable: windowTable, chunk: state, bands: currentBands),
                                path: .streamed)
                        }
                    } catch {
                        let stateError = asFourDGS(error)
                        if firstStateError == nil
                            || (firstStateError?.0.refusalCode == nil
                                && stateError.refusalCode != nil)
                        {
                            firstStateError = (stateError, physicalBandSite(frame))
                        }
                    }
                    return
                }

                guard frame.opcode == Opcode.chunk || frame.opcode == Opcode.deltaChunk else {
                    return
                }
                finishGaussianBirthBands()
                currentState = frame
                currentStateFields = nil
                currentBands.removeAll(keepingCapacity: true)
                currentBandNumbers.removeAll(keepingCapacity: true)
                if frame.opcode == Opcode.deltaChunk && !keyframeDelta {
                    scanReport.error(
                        "the gaussian-birth file contains DeltaChunk at byte \(frame.offset); "
                            + "DeltaChunk belongs only to keyframe-delta")
                    return
                }

                let entries = byOffset[frame.offset] ?? []
                seenEntries.formUnion(entries)
                if !index.isEmpty && entries.isEmpty {
                    scanReport.error(
                        "the \(opcodeName(frame.opcode)) record at byte \(frame.offset) is absent "
                            + "from the Chunk Index")
                }
                for i in entries where index[i].length != frame.total {
                    scanReport.error(
                        "chunk index entry \(i) declares \(index[i].length) bytes for the "
                            + "\(opcodeName(frame.opcode)) record at byte \(frame.offset); its "
                            + "framed length is \(frame.total) bytes")
                    result.indexSafe = false
                }

                var physicalFields: ChunkFields?
                do {
                    if let fields = try chunkFields(source, frame) {
                        physicalFields = fields
                        currentStateFields = fields
                        if keyframeDelta {
                            physicalIntervalCount += 1
                            if !fields.t0.isFinite || !fields.t1.isFinite
                                || fields.t0 >= fields.t1
                            {
                                scanReport.error(
                                    "the physical \(opcodeName(fields.opcode)) interval "
                                        + "[\(fields.t0), \(fields.t1)) must contain two finite "
                                        + "values with t0 < t1")
                            } else {
                                if let previous = previousPhysicalInterval,
                                    previous.t1 != fields.t0
                                {
                                    let what =
                                        fields.t0 < previous.t1 ? "overlap" : "leave a gap"
                                    scanReport.error(
                                        "physical state chunks \(what): [\(previous.t0), "
                                            + "\(previous.t1)) is followed by [\(fields.t0), "
                                            + "\(fields.t1))")
                                } else if previousPhysicalInterval == nil, fields.t0 != 0 {
                                    scanReport.error(
                                        "physical state chunks start at \(fields.t0); expected the "
                                            + "keyframe-delta timeline to start at 0")
                                }
                                previousPhysicalInterval = fields
                            }
                            if !entries.isEmpty { result.fields[frame.offset] = fields }
                        }
                        if !keyframeDelta, fields.opcode == Opcode.chunk {
                            let (sum, overflow) = result.gaussianCount.addingReportingOverflow(
                                UInt64(fields.count))
                            if overflow {
                                scanReport.error(
                                    "the sum of physical Chunk gaussian counts exceeds UInt64")
                            } else {
                                result.gaussianCount = sum
                            }
                        }
                    } else {
                        scanReport.error(
                            "the \(opcodeName(frame.opcode)) record at byte \(frame.offset) is "
                                + "too short for its fixed fields")
                        result.indexSafe = false
                    }
                } catch {
                    scanReport.refused("", asFourDGS(error), walked, nil)
                    result.indexSafe = false
                }

                guard let header, let quantization else { return }
                do {
                    if keyframeDelta {
                        guard let temporalModelOffset else { return }
                        if frame.opcode == Opcode.chunk {
                            try validateGroupHeaders(frame, try keyframeGroup(source, frame))
                            _ = try SceneReader(
                                singleChunkReader(
                                    source, header: header, quantization: quantization,
                                    windowTable: windowTable, chunk: frame,
                                    temporalModelOffset: temporalModelOffset),
                                path: .streamed)
                        } else if let physicalFields {
                            for group in try deltaGroups(source, frame) {
                                try validateGroupHeaders(frame, group)
                                do {
                                    _ = try SceneReader(
                                        deltaGroupReader(
                                            source, header: header, quantization: quantization,
                                            windowTable: windowTable,
                                            temporalModelOffset: temporalModelOffset,
                                            fields: physicalFields, group: group),
                                        path: .streamed)
                                } catch {
                                    let stateError = asFourDGS(error)
                                    if !isExpectedPartialGroupError(stateError, group: group) {
                                        throw stateError
                                    }
                                }
                            }
                        }
                    } else if frame.opcode == Opcode.chunk {
                        _ = try SceneReader(
                            singleChunkReader(
                                source, header: header, quantization: quantization,
                                windowTable: windowTable, chunk: frame),
                            path: .streamed)
                    }
                } catch {
                    let stateError = asFourDGS(error)
                    if firstStateError == nil {
                        firstStateError = (
                            stateError,
                            Site(
                                offset: frame.offset,
                                what:
                                    "the physical \(opcodeName(frame.opcode)) record at byte "
                                    + "\(frame.offset)")
                        )
                    }
                }
            })
    } catch {
        scanReport.refused("", asFourDGS(error), walked, nil)
        result.indexSafe = false
    }
    finishGaussianBirthBands()
    if keyframeDelta {
        if physicalIntervalCount == 0 {
            scanReport.error("the keyframe-delta file contains no physical state chunks")
        } else if let durationSec, let last = previousPhysicalInterval,
            last.t1 != durationSec
        {
            scanReport.error(
                "physical state chunks end at \(last.t1); expected Header duration_sec "
                    + "\(durationSec)")
        }
    }

    if let summary, summary.start < summary.end, !summaryStartsOnBoundary,
        !summaryStructureReported
    {
        scanReport.error(
            "the Footer's summary starts at byte \(summary.start), which is not a record boundary")
    }
    for address in bandsByOffset.values.flatMap({ $0 }) where !seenBands.contains(address.token) {
        scanReport.error(
            "chunk index entry \(address.entry) names band \(address.band) at a range that does "
                + "not frame an intact SH Band Stream record")
        result.indexSafe = false
    }
    for i in index.indices where !seenEntries.contains(i) {
        scanReport.error(
            "chunk index entry \(i) names byte \(index[i].offset), which is not the start of an "
                + "intact physical Chunk or DeltaChunk record")
        result.indexSafe = false
    }
    report.findings.append(contentsOf: scanReport.findings)
    if let firstStateError {
        report.refused(
            "a physical state record does not decode: ", firstStateError.0, walked,
            firstStateError.1)
        result.chunkRefused = true
    }
    return result
}

func validateKeyframeDeltaIndex(
    _ index: [IndexEntry], fields: [UInt64: ChunkFields], durationSec: Double?,
    report: inout Report
) {
    var byOffset: [UInt64: [Int]] = [:]
    for (i, entry) in index.enumerated() { byOffset[entry.offset, default: []].append(i) }
    for (offset, entries) in byOffset where entries.count > 1 {
        report.error(
            "chunk index entries \(entries.map(String.init).joined(separator: ", ")) all name "
                + "byte \(offset); each state record must have one index entry")
    }

    let finite = index.enumerated().filter { $0.element.t0.isFinite && $0.element.t1.isFinite }
    for (i, entry) in index.enumerated() {
        if !entry.t0.isFinite || !entry.t1.isFinite || entry.t0 >= entry.t1 {
            report.error(
                "chunk index entry \(i) has interval [\(entry.t0), \(entry.t1)); expected two "
                    + "finite values with t0 < t1")
        }
    }
    let ordered = finite.sorted { a, b in
        if a.element.t0 == b.element.t0 { return a.offset < b.offset }
        return a.element.t0 < b.element.t0
    }
    for pair in zip(ordered, ordered.dropFirst()) {
        let previous = pair.0.element
        let entry = pair.1.element
        if previous.t1 != entry.t0 {
            let what = entry.t0 < previous.t1 ? "overlap" : "leave a gap"
            report.error(
                "state chunks \(what): [\(previous.t0), \(previous.t1)) is followed by "
                    + "[\(entry.t0), \(entry.t1))")
            break
        }
    }
    if let first = ordered.first?.element, first.t0 != 0 {
        report.error(
            "state chunks start at \(first.t0); expected the keyframe-delta timeline to start at 0")
    }
    if let durationSec, let last = ordered.last?.element, last.t1 != durationSec {
        report.error(
            "state chunks end at \(last.t1); expected Header duration_sec \(durationSec)")
    }

    for (i, entry) in index.enumerated() {
        guard entry.extended else {
            report.error(
                "chunk index entry \(i) has no keyframe-delta fields; expected the appended "
                    + "chunk_kind through live_count block")
            continue
        }
        guard entry.kind == 0 || entry.kind == 1 else {
            report.error(
                "chunk index entry \(i) has chunk_kind \(entry.kind); expected 0 (keyframe) or "
                    + "1 (delta)")
            continue
        }

        if entry.kind == 0 {
            if entry.deltaMode != 0 {
                report.error(
                    "chunk index entry \(i) is a keyframe but delta_mode is \(entry.deltaMode); "
                        + "expected 0")
            }
            if entry.referenceOffset != 0 {
                report.error(
                    "chunk index entry \(i) is a keyframe but reference_offset is "
                        + "\(entry.referenceOffset); expected 0")
            }
            if entry.keyframeOffset != entry.offset {
                report.error(
                    "chunk index entry \(i) is a keyframe but keyframe_offset is "
                        + "\(entry.keyframeOffset); expected its own chunk_offset \(entry.offset)")
            }
            if entry.depth != 0 {
                report.error(
                    "chunk index entry \(i) is a keyframe but depth is \(entry.depth); expected 0")
            }
        } else if entry.deltaMode > 1 {
            report.error(
                "chunk index entry \(i) has delta_mode \(entry.deltaMode); expected 0 "
                    + "(keyframe-referenced) or 1 (chained)")
        }

        if let physical = fields[entry.offset] {
            let expectedOpcode = entry.kind == 0 ? Opcode.chunk : Opcode.deltaChunk
            if physical.opcode != expectedOpcode {
                report.error(
                    "chunk index entry \(i) has chunk_kind \(entry.kind) but points at "
                        + "\(opcodeName(physical.opcode)) at byte \(entry.offset); expected "
                        + "\(opcodeName(expectedOpcode))")
            }
            if physical.t0.bitPattern != entry.t0.bitPattern {
                report.error(
                    "chunk index entry \(i) has t0 \(entry.t0), but the "
                        + "\(opcodeName(physical.opcode)) at byte \(entry.offset) has "
                        + "t0 \(physical.t0)")
            }
            if physical.t1.bitPattern != entry.t1.bitPattern {
                report.error(
                    "chunk index entry \(i) has t1 \(entry.t1), but the "
                        + "\(opcodeName(physical.opcode)) at byte \(entry.offset) has "
                        + "t1 \(physical.t1)")
            }
            if entry.kind == 1 && physical.opcode == Opcode.deltaChunk {
                for (field, indexed, actual) in [
                    ("delta_mode", UInt64(entry.deltaMode), UInt64(physical.deltaMode)),
                    ("reference_offset", entry.referenceOffset, physical.referenceOffset),
                    ("keyframe_offset", entry.keyframeOffset, physical.keyframeOffset),
                    ("depth", UInt64(entry.depth), UInt64(physical.depth)),
                ] where indexed != actual {
                    report.error(
                        "chunk index entry \(i) has \(field) \(indexed), but the DeltaChunk at "
                            + "byte \(entry.offset) has \(field) \(actual)")
                }
            }
        }

    }

    // Resolve the backward-reference DAG once in physical order.
    struct Resolution {
        let keyframe: UInt64
        let depth: Int
    }
    var resolved: [UInt64: Resolution] = [:]
    for i in index.indices.sorted(by: { index[$0].offset < index[$1].offset }) {
        let entry = index[i]
        guard entry.extended, entry.kind == 0 || entry.kind == 1,
            byOffset[entry.offset]?.count == 1
        else { continue }
        if entry.kind == 0 {
            resolved[entry.offset] = Resolution(keyframe: entry.offset, depth: 0)
            continue
        }
        guard entry.deltaMode <= 1 else { continue }
        guard entry.referenceOffset < entry.offset else {
            report.error(
                "the chunk at \(entry.offset) references \(entry.referenceOffset), which is not "
                    + "behind it; references point backwards only")
            continue
        }
        guard let candidates = byOffset[entry.referenceOffset], candidates.count == 1 else {
            report.error(
                "the chunk at \(entry.offset) references \(entry.referenceOffset), which the "
                    + "index does not name exactly once")
            continue
        }
        let reference = index[candidates[0]]
        if entry.deltaMode == 0 && entry.referenceOffset != entry.keyframeOffset {
            report.error(
                "chunk index entry \(i) uses keyframe-referenced delta_mode 0 but references "
                    + "\(entry.referenceOffset); expected keyframe_offset \(entry.keyframeOffset)")
            continue
        }
        if entry.deltaMode == 1 && reference.t1 != entry.t0 {
            report.error(
                "chunk index entry \(i) uses chained delta_mode 1 but references interval "
                    + "[\(reference.t0), \(reference.t1)); expected the state immediately "
                    + "preceding t0 \(entry.t0)")
            continue
        }
        if let physical = fields[entry.offset], let referencePhysical = fields[reference.offset],
            physical.level != referencePhysical.level
        {
            report.error(
                "the DeltaChunk at byte \(entry.offset) has level \(physical.level), but its "
                    + "reference at byte \(reference.offset) has level "
                    + "\(referencePhysical.level); expected equal levels")
        }
        guard let referenceResolution = resolved[reference.offset] else {
            report.error("the chain from chunk \(entry.offset) does not reach a keyframe")
            continue
        }
        let resolution = Resolution(
            keyframe: referenceResolution.keyframe, depth: referenceResolution.depth + 1)
        resolved[entry.offset] = resolution
        if resolution.depth != Int(entry.depth) {
            report.error(
                "the chunk at \(entry.offset) declares depth \(entry.depth), but its chain walks "
                    + "\(resolution.depth) delta chunks; the index and the file disagree about "
                    + "the cost of this seek")
        }
        if entry.keyframeOffset != resolution.keyframe {
            report.error(
                "the chunk at \(entry.offset) declares keyframe_offset "
                    + "\(entry.keyframeOffset), but its chain reaches keyframe "
                    + "\(resolution.keyframe)")
        }
    }
}

private struct AudioSourceSummary {
    let id: UInt32
    let dataLength: UInt64
}

private struct AudioDataSummary {
    let id: UInt32
    let dataLength: UInt64
}

private func malformedAudio(_ frame: Frame, field: String, reason: String) -> FourDGSError {
    .malformed(
        offset: Int64(clamping: frame.offset), record: opcodeName(frame.opcode), field: field,
        reason: reason)
}

private func audioSourceSummary(_ source: ToolReader, _ frame: Frame) throws -> AudioSourceSummary {
    let content = frame.offset + recordHeaderSize
    guard frame.length >= 4 else {
        throw malformedAudio(frame, field: "source_id", reason: "the record is shorter than 4 bytes")
    }
    let idBytes = try source.exactly(offset: content, count: 4, record: "Audio Source source_id")
    let id = readU32(idBytes, at: 0) ?? 0
    var relative: UInt64 = 4
    for field in ["name", "codec", "channel_layout"] {
        guard relative <= frame.length, frame.length - relative >= 4 else {
            throw malformedAudio(frame, field: field, reason: "the string length is missing")
        }
        let lengthBytes = try source.exactly(
            offset: content + relative, count: 4, record: "Audio Source \(field) length")
        let length = UInt64(readU32(lengthBytes, at: 0) ?? 0)
        relative += 4
        guard length <= frame.length - relative else {
            throw malformedAudio(frame, field: field, reason: "the string runs past the record")
        }
        relative += length
    }
    guard relative <= frame.length, frame.length - relative >= 8 else {
        throw malformedAudio(frame, field: "data_length", reason: "the 8-byte field is missing")
    }
    let lengthBytes = try source.exactly(
        offset: content + relative, count: 8, record: "Audio Source data_length")
    return AudioSourceSummary(id: id, dataLength: readU64(lengthBytes, at: 0) ?? 0)
}

private func audioDataSummary(_ source: ToolReader, _ frame: Frame) throws -> AudioDataSummary {
    let content = frame.offset + recordHeaderSize
    guard frame.length >= 12 else {
        throw malformedAudio(
            frame, field: "payload", reason: "the source_id and data length need 12 bytes")
    }
    let fields = try source.exactly(offset: content, count: 12, record: "Audio Data fields")
    let id = readU32(fields, at: 0) ?? 0
    let length = readU64(fields, at: 4) ?? 0
    guard length == frame.length - 12 else {
        throw malformedAudio(
            frame, field: "data",
            reason: "source \(id) declares \(length) bytes; \(frame.length - 12) remain")
    }
    return AudioDataSummary(id: id, dataLength: length)
}

/// Run every check over one size-and-range transport.
func validate(_ source: ToolReader) -> Report {
    var report = Report()

    var firstOpcode: UInt8?
    var lastOpcode: UInt8?
    var hasHeader = false
    var hasQuantization = false
    var hasFooter = false
    var retainedHeaders = 0
    var retainedQuantizations = 0
    var retainedFooters = 0
    var privateCount: UInt64 = 0
    var firstPrivate: (opcode: UInt8, length: UInt64)?
    var provenanceCount: UInt64 = 0
    var firstProvenance: UInt8?
    var unknownCount: UInt64 = 0
    var firstUnknown: UInt8?
    var stateSeen = false
    var pendingFooter: UInt64?
    var audioSources: [UInt32: AudioSourceSummary] = [:]
    var audioData: [UInt32: AudioDataSummary] = [:]
    let walked: Walk
    do {
        walked = try walk(
            source,
            retaining: { frame in
                switch frame.opcode {
                case Opcode.header:
                    defer { retainedHeaders += 1 }
                    return retainedHeaders < 2
                case Opcode.quantization:
                    defer { retainedQuantizations += 1 }
                    return retainedQuantizations < 2
                case Opcode.footer:
                    defer { retainedFooters += 1 }
                    return retainedFooters == 0
                case Opcode.chunkIndex:
                    return true
                default:
                    return false
                }
            },
            visit: { frame, intact in
                guard intact else { return }
                let opcode = frame.opcode
                if let footer = pendingFooter {
                    report.error(
                        "Footer at byte \(footer) is not final; exactly one Footer must be the "
                            + "final record")
                    pendingFooter = nil
                }
                if opcode == Opcode.footer { pendingFooter = frame.offset }
                if firstOpcode == nil { firstOpcode = opcode }
                lastOpcode = opcode
                if opcode == Opcode.header { hasHeader = true }
                if opcode == Opcode.quantization { hasQuantization = true }
                if opcode == Opcode.footer { hasFooter = true }
                if opcode == Opcode.chunk || opcode == Opcode.deltaChunk { stateSeen = true }
                if stateSeen && (opcode == Opcode.audioSource || opcode == Opcode.audioData) {
                    report.error(
                        "\(opcodeName(opcode)) at byte \(frame.offset) appears after the first "
                            + "Chunk or DeltaChunk; audio records must precede state records")
                }
                if opcode == Opcode.audioSource {
                    do {
                        let parsed = try audioSourceSummary(source, frame)
                        if audioSources.updateValue(parsed, forKey: parsed.id) != nil {
                            report.error("Audio Source id \(parsed.id) appears more than once")
                        }
                    } catch {
                        report.error(
                            "Audio Source at byte \(frame.offset) does not parse: "
                                + sentence(asFourDGS(error)))
                    }
                } else if opcode == Opcode.audioData {
                    do {
                        let parsed = try audioDataSummary(source, frame)
                        if audioData.updateValue(parsed, forKey: parsed.id) != nil {
                            report.error("Audio Data id \(parsed.id) appears more than once")
                        }
                    } catch {
                        report.error(
                            "Audio Data at byte \(frame.offset) does not parse: "
                                + sentence(asFourDGS(error)))
                    }
                }
                if opcode == Opcode.attributeStream {
                    report.error(
                        "AttributeStream at byte \(frame.offset) is a bare Chunk structure, not a "
                            + "top-level record")
                } else if isPrivate(opcode) {
                    if firstPrivate == nil { firstPrivate = (opcode, frame.length) }
                    if privateCount < UInt64.max { privateCount += 1 }
                } else if isProvenance(opcode) && !isSpecified(opcode) {
                    if firstProvenance == nil { firstProvenance = opcode }
                    if provenanceCount < UInt64.max { provenanceCount += 1 }
                } else if !isSpecified(opcode) {
                    if firstUnknown == nil { firstUnknown = opcode }
                    if unknownCount < UInt64.max { unknownCount += 1 }
                }
            })
    } catch {
        report.refused("", asFourDGS(error), nil, nil)
        return report
    }

    if let firstPrivate {
        if privateCount == 1 {
            report.note(
                "private record 0x\(hex2(firstPrivate.opcode)) (\(firstPrivate.length) bytes) — "
                    + "skipped, as required")
        } else {
            report.note(
                "\(privateCount) private records — skipped, as required; first is "
                    + "0x\(hex2(firstPrivate.opcode)) (\(firstPrivate.length) bytes)")
        }
    }
    if let firstProvenance {
        let prefix =
            provenanceCount == 1
            ? "reserved provenance record" : "\(provenanceCount) reserved provenance records; first is"
        report.note(
            "\(prefix) 0x\(hex2(firstProvenance)) — skipped, as required "
                + "(0x26-0x2F, section 5.15.8)")
    }
    if let firstUnknown {
        let prefix = unknownCount == 1 ? "unknown record" : "\(unknownCount) unknown records; first is"
        report.note("\(prefix) 0x\(hex2(firstUnknown)) — skipped, as required")
    }

    if !walked.trailingMagic {
        report.error(
            "file does not end with the magic; it is truncated or was written by a broken encoder")
    }

    if let cut = walked.cut {
        report.note(
            "the file is cut at byte \(commas(cut.at)): \(cut.reason). The \(walked.intact) "
                + "complete records before it are intact, and a streamed reader recovers them")
    }

    guard let firstOpcode else {
        report.error("no records at all")
        return report
    }
    if firstOpcode != Opcode.header {
        report.error("first record is \(opcodeName(firstOpcode)); the Header must come first")
    }
    if !hasHeader { report.error("no Header record") }
    if !hasQuantization { report.error("no Quantization record") }
    if !hasFooter { report.error("no Footer record") }
    if hasFooter && lastOpcode != Opcode.footer {
        report.error(
            "last record is \(opcodeName(lastOpcode ?? 0)); the Footer must be the final record")
    }

    let dispatch: HeaderDispatch?
    do {
        dispatch = try headerDispatch(source, walked)
    } catch {
        report.refused("", asFourDGS(error), walked, nil)
        return report
    }
    let keyframeDelta = dispatch?.keyframeDelta ?? false

    for (id, descriptor) in audioSources {
        guard let payload = audioData[id] else {
            report.error("Audio Source id \(id) has no matching Audio Data record")
            continue
        }
        if descriptor.dataLength != payload.dataLength {
            report.error(
                "Audio Source id \(id) declares \(descriptor.dataLength) data bytes, but its "
                    + "Audio Data record carries \(payload.dataLength)")
        }
    }
    for id in audioData.keys where audioSources[id] == nil {
        report.error("Audio Data id \(id) has no matching Audio Source record")
    }
    if let dispatch {
        let hasAudioRecords = !audioSources.isEmpty || !audioData.isEmpty
        if dispatch.hasAudio != hasAudioRecords {
            let declaration = dispatch.hasAudio ? "set" : "clear"
            report.error(
                "Header has-audio flag is \(declaration), but the file "
                    + (hasAudioRecords ? "contains audio records" : "contains no audio records"))
        }
    }

    let summary: SummaryDeclaration?
    do {
        summary = try summaryDeclaration(source, walked)
    } catch {
        report.refused("", asFourDGS(error), walked, nil)
        return report
    }
    let indexRange: Range<UInt64>
    if let summary, summary.start < summary.end {
        indexRange = summary.start..<summary.end
    } else {
        indexRange = 0..<0
    }
    for frame in walked.intactRecords where frame.opcode == Opcode.chunkIndex {
        let (end, overflow) = frame.offset.addingReportingOverflow(frame.total)
        if overflow || !indexRange.contains(frame.offset) || end > indexRange.upperBound {
            report.error(
                "ChunkIndex at byte \(frame.offset) lies outside the Footer-declared summary")
        }
    }

    let index: [IndexEntry]
    do {
        index = try chunkIndexEntries(source, walked, within: indexRange)
    } catch {
        report.refused("", asFourDGS(error), walked, nil)
        return report
    }
    var indexBoundsSafe = true
    for (i, entry) in index.enumerated() {
        let (end, overflow) = entry.offset.addingReportingOverflow(entry.length)
        if overflow || end > walked.size || entry.offset >= walked.size {
            report.error("chunk index entry \(i) points past the end of the file")
            indexBoundsSafe = false
            continue
        }
        let at: UInt8
        do {
            at = try source.exactly(offset: entry.offset, count: 1, record: "Chunk Index target")[0]
        } catch {
            report.refused("", asFourDGS(error), walked, nil)
            indexBoundsSafe = false
            continue
        }
        if at != Opcode.chunk && !(keyframeDelta && at == Opcode.deltaChunk) {
            let expected = keyframeDelta ? "a Chunk or DeltaChunk record" : "a Chunk record"
            report.error("chunk index entry \(i) does not point at \(expected)")
            indexBoundsSafe = false
        }
        if !keyframeDelta && entry.extended {
            report.error(
                "chunk index entry \(i) carries keyframe-delta fields in a gaussian-birth file")
            indexBoundsSafe = false
        }
        for band in entry.bands {
            let (bandEnd, bandOverflow) = band.offset.addingReportingOverflow(band.length)
            if bandOverflow || bandEnd > walked.size || band.offset >= walked.size {
                report.error(
                    "band \(band.band) of chunk index entry \(i) points past the end of the file")
                indexBoundsSafe = false
                continue
            }
            do {
                let opcode = try source.exactly(
                    offset: band.offset, count: 1, record: "Chunk Index band target")[0]
                if opcode != Opcode.shBandStream {
                    report.error(
                        "band \(band.band) of chunk index entry \(i) does not point at an SH Band "
                            + "Stream record")
                    indexBoundsSafe = false
                }
            } catch {
                report.refused("", asFourDGS(error), walked, nil)
                indexBoundsSafe = false
            }
        }
    }

    if let summary {
        if summary.start == summary.end {
            report.error(
                "the Footer's nonzero summary_start \(summary.start) names no ChunkIndex record")
        } else if summary.start > summary.end {
            report.error(
                "the Footer's summary starts at \(summary.start), after the summary ends at "
                    + "\(summary.end)")
        } else {
            do {
                if let covered = try coverage(source, walked), !covered.ok {
                    report.error(
                        "summary CRC mismatch: the index is untrustworthy "
                            + "(a streamed read still works)")
                }
            } catch {
                report.refused("", asFourDGS(error), walked, nil)
                return report
            }
        }
    }

    if hasHeader && index.isEmpty {
        report.warn("no chunk index: this file can only be read front to back, not seeked")
    }

    let physical = validatePhysicalRecords(
        source, walked, index: index, keyframeDelta: keyframeDelta,
        temporalModelOffset: dispatch?.temporalModelOffset, durationSec: dispatch?.durationSec,
        shDegree: dispatch?.shDegree, summary: summary,
        indexBoundsSafe: indexBoundsSafe,
        report: &report)
    if keyframeDelta {
        validateKeyframeDeltaIndex(
            index, fields: physical.fields, durationSec: dispatch?.durationSec, report: &report)
        report.incomplete(
            "keyframe-delta identity composition was not checked: the current ranged Swift ABI "
                + "exposes groups and references, but not composed identity state")
    } else {
        if let expected = dispatch?.gaussianCount, physical.gaussianCount != expected {
            report.error(
                "Header gaussian_count is \(expected), but physical Chunks contain "
                    + "\(physical.gaussianCount) gaussians")
        }
        checkGaussianBirth(
            source, walked, index, indexSafe: physical.indexSafe,
            chunkAlreadyRefused: physical.chunkRefused, &report)
    }

    return report
}

public func validate(_ bytes: [UInt8]) -> Report {
    validate(ToolReader(InMemoryReader(bytes)))
}

/// Open the indexed reader and decode chunks only after physical ranges have been proved.
private func checkGaussianBirth(
    _ source: ToolReader, _ walked: Walk, _ index: [IndexEntry], indexSafe: Bool,
    chunkAlreadyRefused: Bool, _ report: inout Report
) {
    // Never hand an unverified declared range to the indexed core. A forged length that stays
    // inside the resource can still size an attacker-controlled allocation; the physical framing
    // pass above must prove every range first.
    guard indexSafe else { return }
    let reader: SceneReader
    do {
        reader = try SceneReader(source, path: .indexed)
    } catch {
        report.refused(
            "a seeking reader cannot open this file: ", asFourDGS(error), walked, nil)
        return
    }
    if !chunkAlreadyRefused, let refusal = scanChunks(reader, index: index) {
        report.refused("a chunk does not decode: ", refusal.error, walked, refusal.site)
    }
}

/// `4dgs validate <file>` — check a file against the specification.
public func runValidate(_ path: String, _ out: TextOutput, _ err: TextOutput) -> Int32 {
    let source: ToolReader
    do {
        source = try ToolReader(FileReader(path: path))
    } catch {
        err.line("4dgs: \(path): \(sentence(asFourDGS(error)))")
        return exitTool
    }
    let report = validate(source)
    for finding in report.findings {
        out.line("\(finding.severity.name): \(finding.message)")
        if let refusal = finding.refusal { out.line("  \(refusal)") }
    }
    if report.findings.contains(where: { $0.severity == .error }) {
        err.line("INVALID")
        return exitFailed
    }
    if !report.complete {
        err.line("INCOMPLETE")
        return exitWarnings
    }
    out.line(report.findings.isEmpty ? "valid" : "valid (with notes)")
    return report.worst == .warning ? exitWarnings : exitOk
}
