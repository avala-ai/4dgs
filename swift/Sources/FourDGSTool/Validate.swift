// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Bounded structural validation aligned with the Python reference validator.
///
/// Swift leaves full record parsing to the core binding. This layer checks framing, indexed
/// metadata, summary structure, and every physical state stream without buffering whole records.

import FourDGS

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

    public var ok: Bool { !findings.contains { $0.severity == .error } }
    public var worst: Severity? { findings.map(\.severity).max() }

    mutating func push(_ severity: Severity, _ message: String, _ refusal: Named?) {
        findings.append(Finding(severity: severity, message: message, refusal: refusal))
    }

    mutating func error(_ message: String) { push(.error, message, nil) }
    mutating func warn(_ message: String) { push(.warning, message, nil) }
    mutating func note(_ message: String) { push(.note, message, nil) }

    /// Preserve the shared diagnostic sentence while attaching Swift's placed refusal.
    mutating func refused(_ prefix: String, _ error: FourDGSError, _ walk: Walk?, _ site: Site?) {
        push(.error, prefix + sentence(error), describe(error, walk: walk, site: site))
    }
}

private struct SourceSlice {
    let offset: UInt64
    let length: UInt64
    let literal: [UInt8]?

    init(offset: UInt64, length: UInt64) {
        self.offset = offset
        self.length = length
        self.literal = nil
    }

    init(literal: [UInt8]) {
        self.offset = 0
        self.length = UInt64(literal.count)
        self.literal = literal
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
                bytes = try source.read(offset: readOffset, count: Int(take))
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
    let deltaMode: UInt8
    let referenceOffset: UInt64
    let keyframeOffset: UInt64
    let depth: UInt16
}

private struct PhysicalValidation {
    var fields: [UInt64: ChunkFields] = [:]
    var indexSafe = true
    var chunkRefused = false
}

private func chunkFields(_ source: ToolReader, _ frame: Frame) throws -> ChunkFields? {
    let fixed: UInt64 = frame.opcode == Opcode.deltaChunk ? 39 : 20
    guard frame.length >= fixed else { return nil }
    let bytes = try source.exactly(
        offset: frame.offset + recordHeaderSize, count: Int(fixed), record: opcodeName(frame.opcode))
    guard let t0 = readF64(bytes, at: 0), let t1 = readF64(bytes, at: 8),
        let level = readU32(bytes, at: 16)
    else { return nil }
    if frame.opcode == Opcode.chunk {
        return ChunkFields(
            opcode: frame.opcode, t0: t0, t1: t1, level: level, deltaMode: 0,
            referenceOffset: 0, keyframeOffset: frame.offset, depth: 0)
    }
    guard let referenceOffset = readU64(bytes, at: 21),
        let keyframeOffset = readU64(bytes, at: 29), let depth = readU16(bytes, at: 37)
    else { return nil }
    return ChunkFields(
        opcode: frame.opcode, t0: t0, t1: t1, level: level, deltaMode: bytes[20],
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
    temporalModelOffset: UInt64? = nil
) -> SlicedReader {
    var slices = frontMatterSlices(
        header: header, quantization: quantization, windowTable: windowTable,
        temporalModelOffset: temporalModelOffset)
    slices.append(SourceSlice(offset: chunk.offset, length: chunk.total))
    return SlicedReader(source: source, slices: slices)
}

private struct DeltaGroup {
    let name: String
    let count: UInt32
    let offset: UInt64
    let length: UInt64
}

private func malformedDelta(_ frame: Frame, _ reason: String) -> FourDGSError {
    .malformed(
        offset: Int64(clamping: frame.offset), record: "DeltaChunk", field: "groups",
        reason: reason)
}

private func deltaGroups(_ source: ToolReader, _ frame: Frame) throws -> [DeltaGroup] {
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
    guard uncompressed == recordsLength else {
        throw malformedDelta(
            frame,
            "uncompressed_size is \(uncompressed), but the records blob is \(recordsLength) bytes")
    }
    guard relative + recordsLength == frame.length else {
        throw malformedDelta(frame, "bytes remain after the records blob")
    }

    let recordsEnd = relative + recordsLength
    let names = ["update", "birth", "death"]
    var groups: [DeltaGroup] = []
    for i in 0..<3 {
        guard relative <= recordsEnd, recordsEnd - relative >= 8 else {
            throw malformedDelta(frame, "the \(names[i]) group length is missing")
        }
        let field = try source.exactly(
            offset: content + relative, count: 8, record: "DeltaChunk \(names[i]) length")
        let length = readU64(field, at: 0) ?? 0
        relative += 8
        guard length <= recordsEnd - relative else {
            throw malformedDelta(frame, "the \(names[i]) group runs past the records blob")
        }
        groups.append(
            DeltaGroup(
                name: names[i], count: declaredCounts[i], offset: content + relative,
                length: length))
        relative += length
    }
    guard relative == recordsEnd else {
        throw malformedDelta(frame, "bytes remain after the death group")
    }
    return groups
}

private let requiredGroupAttributes: Set<UInt8> = Set(0...10)
private let invariantUpdateAttributes: Set<UInt8> = [8, 9, 10]

private func validateGroupHeaders(
    _ source: ToolReader, _ frame: Frame, _ group: DeltaGroup
) throws {
    if group.length == 0 {
        guard group.count == 0 else {
            throw malformedDelta(
                frame, "the \(group.name) group declares \(group.count) rows but has no streams")
        }
        return
    }
    var relative: UInt64 = 0
    var attributes: Set<UInt8> = []
    while relative < group.length {
        guard group.length - relative >= 17 else {
            throw malformedDelta(frame, "the \(group.name) group ends inside a stream header")
        }
        let header = try source.exactly(
            offset: group.offset + relative, count: 17,
            record: "DeltaChunk \(group.name) stream")
        let attribute = header[0]
        guard attributes.insert(attribute).inserted else {
            throw malformedDelta(
                frame, "the \(group.name) group carries attribute \(attribute) twice")
        }
        let count = readU32(header, at: 5) ?? 0
        guard count == group.count else {
            throw malformedDelta(
                frame,
                "the \(group.name) group declares \(group.count) rows, but attribute "
                    + "\(attribute) carries \(count)")
        }
        let payload = readU64(header, at: 9) ?? 0
        relative += 17
        guard payload <= group.length - relative else {
            throw malformedDelta(
                frame, "attribute \(attribute) in the \(group.name) group runs past the group")
        }
        relative += payload
    }
    guard attributes.contains(13) else {
        throw malformedDelta(frame, "the \(group.name) group carries no gaussian_id stream")
    }
    if group.name == "birth" {
        let missing = requiredGroupAttributes.subtracting(attributes).sorted()
        guard missing.isEmpty else {
            throw malformedDelta(frame, "the birth group is missing required attributes \(missing)")
        }
    } else if group.name == "update" {
        let forbidden = invariantUpdateAttributes.intersection(attributes).sorted()
        guard forbidden.isEmpty else {
            throw malformedDelta(
                frame, "the update group carries lifetime-invariant attributes \(forbidden)")
        }
    } else {
        let surplus = attributes.subtracting([13]).sorted()
        guard surplus.isEmpty else {
            throw malformedDelta(frame, "the death group carries non-identity attributes \(surplus)")
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
    temporalModelOffset: UInt64, fields: ChunkFields, group: DeltaGroup
) -> SlicedReader {
    var slices = frontMatterSlices(
        header: header, quantization: quantization, windowTable: windowTable,
        temporalModelOffset: temporalModelOffset)
    slices.append(
        SourceSlice(
            literal: syntheticChunkPrefix(
                t0: fields.t0, t1: fields.t1, level: fields.level, count: group.count,
                streams: group.length)))
    slices.append(SourceSlice(offset: group.offset, length: group.length))
    return SlicedReader(source: source, slices: slices)
}

private func isExpectedPartialGroupError(_ error: FourDGSError, group: DeltaGroup) -> Bool {
    group.name != "birth" && sentence(error).contains("chunk is missing required attributes")
}

private func isChunkRefusal(_ error: FourDGSError) -> Bool {
    error.refusalCode == .unknownStreamCodec || error.refusalCode == .windowIndexOutOfRange
}

private func validatePhysicalRecords(
    _ source: ToolReader, _ walked: Walk, index: [IndexEntry], keyframeDelta: Bool,
    temporalModelOffset: UInt64?, summary: SummaryDeclaration?, indexBoundsSafe: Bool,
    report: inout Report
) -> PhysicalValidation {
    var result = PhysicalValidation(indexSafe: indexBoundsSafe)
    var scanReport = Report()
    var byOffset: [UInt64: [Int]] = [:]
    for (i, entry) in index.enumerated() { byOffset[entry.offset, default: []].append(i) }
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

    var header: Frame?
    var quantization: Frame?
    var windowTable: Frame?
    var firstStateError: (FourDGSError, Site)?
    var summaryStartsOnBoundary = summary?.start == summary?.end
    var summaryStructureReported = false

    do {
        _ = try walk(
            source, retaining: { _ in false },
            visit: { frame, intact in
                guard intact else { return }

                switch frame.opcode {
                case Opcode.header: header = frame
                case Opcode.quantization: quantization = frame
                case Opcode.windowTable: windowTable = frame
                default: break
                }

                if let summary, summary.start <= summary.end {
                    let frameEnd = frame.offset + frame.total
                    if frame.offset == summary.start { summaryStartsOnBoundary = true }
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
                    for address in bandsByOffset[frame.offset] ?? [] {
                        seenBands.insert(address.token)
                        if address.length != frame.total {
                            scanReport.error(
                                "chunk index entry \(address.entry) declares \(address.length) "
                                    + "bytes for the SH Band Stream at byte \(frame.offset); its "
                                    + "framed length is \(frame.total) bytes")
                            result.indexSafe = false
                        }
                        if frame.length > 0 {
                            do {
                                let physicalBand = try source.exactly(
                                    offset: frame.offset + recordHeaderSize, count: 1,
                                    record: "SH Band Stream band")[0]
                                if physicalBand != address.band {
                                    scanReport.error(
                                        "chunk index entry \(address.entry) names band "
                                            + "\(address.band), but the SH Band Stream at byte "
                                            + "\(frame.offset) names band \(physicalBand)")
                                    result.indexSafe = false
                                }
                            } catch {
                                scanReport.refused("", asFourDGS(error), walked, nil)
                                result.indexSafe = false
                            }
                        }
                    }
                    return
                }

                guard frame.opcode == Opcode.chunk || frame.opcode == Opcode.deltaChunk else {
                    return
                }
                if frame.opcode == Opcode.deltaChunk && !keyframeDelta {
                    scanReport.error(
                        "the gaussian-birth file contains DeltaChunk at byte \(frame.offset); "
                            + "DeltaChunk belongs only to keyframe-delta")
                    return
                }

                let entries = byOffset[frame.offset] ?? []
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
                if keyframeDelta {
                    do {
                        if let fields = try chunkFields(source, frame) {
                            result.fields[frame.offset] = fields
                            physicalFields = fields
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
                }

                guard firstStateError == nil, let header, let quantization
                else { return }
                do {
                    if keyframeDelta {
                        guard let temporalModelOffset else { return }
                        if frame.opcode == Opcode.chunk {
                            _ = try SceneReader(
                                singleChunkReader(
                                    source, header: header, quantization: quantization,
                                    windowTable: windowTable, chunk: frame,
                                    temporalModelOffset: temporalModelOffset),
                                path: .streamed)
                        } else if let physicalFields {
                            for group in try deltaGroups(source, frame) {
                                try validateGroupHeaders(source, frame, group)
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
                    if keyframeDelta || isChunkRefusal(stateError) {
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
                if firstOpcode == nil { firstOpcode = opcode }
                lastOpcode = opcode
                if opcode == Opcode.header { hasHeader = true }
                if opcode == Opcode.quantization { hasQuantization = true }
                if opcode == Opcode.footer { hasFooter = true }
                if isPrivate(opcode) {
                    report.note(
                        "private record 0x\(hex2(opcode)) (\(frame.length) bytes) — skipped, as required")
                } else if isProvenance(opcode) && !isSpecified(opcode) {
                    report.note(
                        "reserved provenance record 0x\(hex2(opcode)) — skipped, as required "
                            + "(0x26-0x2F, section 5.15.8)")
                } else if !isSpecified(opcode) {
                    report.note("unknown record 0x\(hex2(opcode)) — skipped, as required")
                }
            })
    } catch {
        report.refused("", asFourDGS(error), nil, nil)
        return report
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

    let index: [IndexEntry]
    do {
        index = try chunkIndexEntries(source, walked)
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

    let summary: SummaryDeclaration?
    do {
        summary = try summaryDeclaration(source, walked)
    } catch {
        report.refused("", asFourDGS(error), walked, nil)
        return report
    }
    if let summary {
        if summary.start > summary.end {
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
        temporalModelOffset: dispatch?.temporalModelOffset, summary: summary,
        indexBoundsSafe: indexBoundsSafe,
        report: &report)
    if keyframeDelta {
        validateKeyframeDeltaIndex(
            index, fields: physical.fields, durationSec: dispatch?.durationSec, report: &report)
    } else {
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
    if !report.ok {
        err.line("INVALID")
        return exitFailed
    }
    out.line(report.findings.isEmpty ? "valid" : "valid (with notes)")
    return report.worst == .warning ? exitWarnings : exitOk
}
