// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import FourDGS

public let magic: [UInt8] = [0x89, 0x34, 0x44, 0x47, 0x53, 0x31, 0x0D, 0x0A]
public let recordHeaderSize: UInt64 = 9

public enum Opcode {
    public static let header: UInt8 = 0x01
    public static let footer: UInt8 = 0x02
    public static let quantization: UInt8 = 0x03
    public static let windowTable: UInt8 = 0x04
    public static let chunk: UInt8 = 0x05
    public static let attributeStream: UInt8 = 0x06
    public static let shBandStream: UInt8 = 0x07
    public static let chunkIndex: UInt8 = 0x08
    public static let audio: UInt8 = 0x09
    public static let statistics: UInt8 = 0x0C
    public static let attachment: UInt8 = 0x0D
    public static let attachmentIndex: UInt8 = 0x0E
    public static let summaryOffset: UInt8 = 0x0F
    public static let deltaChunk: UInt8 = 0x10
    public static let audioSource: UInt8 = 0x11
    public static let audioData: UInt8 = 0x12
    public static let coordinateFrame: UInt8 = 0x20
    public static let objectTrack: UInt8 = 0x25
    public static let provenanceEnd: UInt8 = 0x30
    public static let privateStart: UInt8 = 0x80
}

public func opcodeName(_ opcode: UInt8) -> String {
    switch opcode {
    case 0x01: return "Header"
    case 0x02: return "Footer"
    case 0x03: return "Quantization"
    case 0x04: return "WindowTable"
    case 0x05: return "Chunk"
    case 0x06: return "AttributeStream"
    case 0x07: return "ShBandStream"
    case 0x08: return "ChunkIndex"
    case 0x09: return "Audio"
    case 0x0A: return "Camera"
    case 0x0B: return "Metadata"
    case 0x0C: return "Statistics"
    case 0x0D: return "Attachment"
    case 0x0E: return "AttachmentIndex"
    case 0x0F: return "SummaryOffset"
    case 0x10: return "DeltaChunk"
    case 0x11: return "Audio Source"
    case 0x12: return "Audio Data"
    case 0x20: return "CoordinateFrame"
    case 0x21: return "SensorCalibration"
    case 0x22: return "RigTrajectory"
    case 0x23: return "GeodeticAnchor"
    case 0x24: return "ObjectTable"
    case 0x25: return "ObjectTrack"
    default:
        return "\(isPrivate(opcode) ? "Private" : "Unknown")(0x\(hex2(opcode)))"
    }
}

public func isPrivate(_ opcode: UInt8) -> Bool { opcode >= Opcode.privateStart }

public func isProvenance(_ opcode: UInt8) -> Bool {
    opcode >= Opcode.coordinateFrame && opcode < Opcode.provenanceEnd
}

/// Attachment Index is reserved without a defined body and writers MUST NOT emit it, so it is not
/// a record an implementation can claim to support; AttributeStream is a bare Chunk structure
/// rather than a top-level record. Neither counts as specified.
public func isSpecified(_ opcode: UInt8) -> Bool {
    (opcode >= Opcode.header && opcode <= Opcode.audioData && opcode != Opcode.attributeStream
        && opcode != Opcode.attachmentIndex)
        || (opcode >= Opcode.coordinateFrame && opcode <= Opcode.objectTrack)
}

public func hex2(_ value: UInt8) -> String {
    let digits = Array("0123456789ABCDEF")
    return String(digits[Int(value >> 4)]) + String(digits[Int(value & 0x0F)])
}

public func commas(_ value: UInt64) -> String {
    let digits = Array(String(value))
    var out = ""
    for (i, digit) in digits.enumerated() {
        if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
        out.append(digit)
    }
    return out
}

public func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc & 1) != 0 ? (0xEDB8_8320 ^ (crc >> 1)) : (crc >> 1)
        }
    }
    return crc ^ 0xFFFF_FFFF
}

final class ToolReader: ByteRangeReader {
    private var base: any ByteRangeReader

    init(_ base: any ByteRangeReader) { self.base = base }

    func byteCount() throws -> Int64 { try base.byteCount() }

    func read(offset: Int64, count: Int) throws -> [UInt8] {
        try base.read(offset: offset, count: count)
    }

    func size() throws -> UInt64 {
        let count = try byteCount()
        guard count >= 0 else { throw FourDGSError.invalidRange(offset: count, count: 0) }
        return UInt64(count)
    }

    func exactly(offset: UInt64, count: Int, record: String) throws -> [UInt8] {
        guard let signed = Int64(exactly: offset) else {
            throw FourDGSError.invalidRange(offset: Int64.max, count: count)
        }
        let bytes = try read(offset: signed, count: count)
        guard bytes.count == count else {
            throw FourDGSError.truncated(
                offset: signed, record: record, needed: Int64(count), available: Int64(bytes.count))
        }
        return bytes
    }
}

public struct Frame: Equatable {
    public let opcode: UInt8
    public let offset: UInt64
    public let length: UInt64

    public var total: UInt64 {
        let (total, overflow) = length.addingReportingOverflow(recordHeaderSize)
        return overflow ? UInt64.max : total
    }

    var overflows: Bool { length.addingReportingOverflow(recordHeaderSize).overflow }
}

public struct Cut {
    public let at: UInt64
    public let reason: String
    public let insideARecord: Bool
}

public struct Walk {
    public var records: [Frame] = []
    public var cut: Cut?
    public var trailingMagic = false
    public var size: UInt64 = 0
    public var recordCount = 0
    fileprivate var intactRecordCount = 0
    fileprivate var retainedIntactCount = 0

    public var intactRecords: ArraySlice<Frame> {
        let count =
            recordCount == 0 && !records.isEmpty
            ? records.count - ((cut?.insideARecord ?? false) ? 1 : 0)
            : retainedIntactCount
        return records.prefix(count)
    }

    public func firstIntact(_ opcode: UInt8) -> Frame? {
        intactRecords.first { $0.opcode == opcode }
    }

    public var intact: Int {
        recordCount == 0 && !records.isEmpty
            ? records.count - ((cut?.insideARecord ?? false) ? 1 : 0)
            : intactRecordCount
    }
}

func readU64(_ bytes: [UInt8], at: UInt64) -> UInt64? {
    guard at <= UInt64(bytes.count), UInt64(bytes.count) - at >= 8 else { return nil }
    let start = Int(at)
    var value: UInt64 = 0
    for i in (0..<8).reversed() { value = (value << 8) | UInt64(bytes[start + i]) }
    return value
}

func readU32(_ bytes: [UInt8], at: UInt64) -> UInt32? {
    guard at <= UInt64(bytes.count), UInt64(bytes.count) - at >= 4 else { return nil }
    let start = Int(at)
    var value: UInt32 = 0
    for i in (0..<4).reversed() { value = (value << 8) | UInt32(bytes[start + i]) }
    return value
}

func readF64(_ bytes: [UInt8], at: UInt64) -> Double? {
    readU64(bytes, at: at).map(Double.init(bitPattern:))
}

func walk(
    _ source: ToolReader, retaining: (Frame) -> Bool,
    visit: ((Frame, Bool) -> Void)? = nil
) throws -> Walk {
    let size = try source.size()
    guard size >= UInt64(magic.count) else {
        throw FourDGSError.truncated(
            offset: 0, record: "magic", needed: Int64(magic.count), available: Int64(size))
    }
    let head = try source.exactly(offset: 0, count: magic.count, record: "magic")
    if head != magic { throw refuseMagic(head) }

    var out = Walk()
    out.size = size
    var at = UInt64(magic.count)
    while true {
        let remaining = size - at
        if remaining == 0 { break }
        if remaining <= UInt64(magic.count) {
            let tail = try source.exactly(
                offset: at, count: Int(remaining), record: "trailing magic")
            out.trailingMagic = tail == magic
            if !out.trailingMagic {
                out.cut = Cut(
                    at: at,
                    reason: "\(commas(remaining)) trailing bytes are neither a record nor the magic",
                    insideARecord: false)
            }
            break
        }
        if remaining < recordHeaderSize {
            out.cut = Cut(
                at: at, reason: "\(commas(remaining)) bytes are too few for a record header",
                insideARecord: false)
            break
        }
        let header = try source.exactly(
            offset: at, count: Int(recordHeaderSize), record: "record header")
        let frame = Frame(opcode: header[0], offset: at, length: readU64(header, at: 1) ?? 0)
        out.recordCount += 1

        let (end, overflow) = at.addingReportingOverflow(frame.total)
        if frame.overflows || overflow || end > size {
            if retaining(frame) { out.records.append(frame) }
            visit?(frame, false)
            out.cut = Cut(
                at: at,
                reason:
                    "the \(opcodeName(frame.opcode)) record declares \(commas(frame.length)) bytes, "
                    + "past the end of a \(commas(size))-byte file",
                insideARecord: true)
            break
        }
        if retaining(frame) {
            out.records.append(frame)
            out.retainedIntactCount += 1
        }
        out.intactRecordCount += 1
        visit?(frame, true)
        at = end
    }
    return out
}

public struct Site {
    public let offset: UInt64
    public let what: String

    public init(offset: UInt64, what: String) {
        self.offset = offset
        self.what = what
    }
}

public struct Named: CustomStringConvertible {
    public let code: RefusalCode
    public let site: Site?

    public var description: String {
        guard let site else { return "refusal \(code.rawValue)" }
        return "refusal \(code.rawValue) at byte \(site.offset) (\(site.what))"
    }
}

func frontMatterSite(_ walk: Walk?, _ code: RefusalCode) -> Site? {
    let opcode: UInt8
    let what: String
    switch code {
    case .magicMismatch, .unsupportedMajorVersion:
        return Site(offset: 0, what: "the magic")
    case .unknownTemporalModel:
        opcode = Opcode.header
        what = "the Header record"
    case .unknownQuantizationScheme:
        opcode = Opcode.quantization
        what = "the Quantization record"
    case .unknownStreamCodec, .windowIndexOutOfRange:
        return nil
    }
    guard let walk else { return nil }
    let candidates = walk.intactRecords.filter { $0.opcode == opcode }
    guard candidates.count == 1, let frame = candidates.first else { return nil }
    return Site(offset: frame.offset, what: what)
}

public func describe(_ error: FourDGSError, walk: Walk?, site: Site?) -> Named? {
    guard let code = error.refusalCode else { return nil }
    return Named(code: code, site: site ?? frontMatterSite(walk, code))
}

public struct IndexEntry {
    public let t0: Double
    public let t1: Double
    public let offset: UInt64
    public let length: UInt64
    public let gaussianCount: UInt32
    public let bands: [(band: UInt8, offset: UInt64, length: UInt64)]
    public let extended: Bool
    public let kind: UInt8
    public let deltaMode: UInt8
    public let referenceOffset: UInt64
    public let keyframeOffset: UInt64
    public let depth: UInt16
    public let liveCount: UInt64
}

func chunkIndexEntries(
    _ source: ToolReader, _ walk: Walk, within summaryRange: Range<UInt64>? = nil
) throws -> [IndexEntry] {
    let t0Field: UInt64 = 0
    let t1Field: UInt64 = 8
    let offsetField: UInt64 = 16
    let bandCountField: UInt64 = 36
    let prefix: UInt64 = 40
    let bandEntrySize: UInt64 = 17
    let deltaBlockSize: UInt64 = 28
    var out: [IndexEntry] = []
    for frame in walk.intactRecords where frame.opcode == Opcode.chunkIndex {
        if let summaryRange {
            let (end, overflow) = frame.offset.addingReportingOverflow(frame.total)
            guard !overflow, summaryRange.contains(frame.offset), end <= summaryRange.upperBound else {
                continue
            }
        }
        let content = frame.offset + recordHeaderSize
        guard frame.length >= prefix else {
            throw FourDGSError.malformed(
                offset: Int64(clamping: frame.offset), record: "ChunkIndex", field: "fixed fields",
                reason: "the record has \(frame.length) bytes; expected at least \(prefix)")
        }
        let fields = try source.exactly(
            offset: content, count: Int(prefix), record: "Chunk Index")
        guard let t0 = readF64(fields, at: t0Field), let t1 = readF64(fields, at: t1Field),
            let offset = readU64(fields, at: offsetField),
            let length = readU64(fields, at: offsetField + 8),
            let gaussianCount = readU32(fields, at: 32)
        else { continue }
        var bands: [(band: UInt8, offset: UInt64, length: UInt64)] = []
        let declared = UInt64(readU32(fields, at: bandCountField) ?? 0)
        guard declared <= 3 else {
            throw FourDGSError.malformed(
                offset: Int64(clamping: content + bandCountField), record: "ChunkIndex",
                field: "band_count", reason: "the record declares \(declared) bands; expected 0-3")
        }
        var at = content + prefix
        let available = (frame.length - prefix) / bandEntrySize
        for _ in 0..<min(declared, available) {
            let field = try source.exactly(
                offset: at, count: Int(bandEntrySize), record: "Chunk Index band range")
            guard let bandOffset = readU64(field, at: 1), let bandLength = readU64(field, at: 9)
            else { break }
            guard (1...3).contains(field[0]) else {
                throw FourDGSError.malformed(
                    offset: Int64(clamping: at), record: "ChunkIndex", field: "band",
                    reason: "the entry names band \(field[0]); expected 1, 2, or 3")
            }
            bands.append((band: field[0], offset: bandOffset, length: bandLength))
            at += bandEntrySize
        }

        let (bandBytes, bandOverflow) = declared.multipliedReportingOverflow(by: bandEntrySize)
        let (extensionAt, extensionOverflow) = prefix.addingReportingOverflow(bandBytes)
        let hasExtension =
            !bandOverflow && !extensionOverflow && extensionAt <= frame.length
            && frame.length - extensionAt >= deltaBlockSize
        var kind: UInt8 = 0
        var deltaMode: UInt8 = 0
        var referenceOffset: UInt64 = 0
        var keyframeOffset: UInt64 = 0
        var depth: UInt16 = 0
        var liveCount: UInt64 = 0
        if hasExtension {
            let extensionFields = try source.exactly(
                offset: content + extensionAt, count: Int(deltaBlockSize),
                record: "Chunk Index keyframe-delta fields")
            kind = extensionFields[0]
            deltaMode = extensionFields[1]
            referenceOffset = readU64(extensionFields, at: 2) ?? 0
            keyframeOffset = readU64(extensionFields, at: 10) ?? 0
            depth = readU16(extensionFields, at: 18) ?? 0
            liveCount = readU64(extensionFields, at: 20) ?? 0
        }
        out.append(
            IndexEntry(
                t0: t0, t1: t1, offset: offset, length: length,
                gaussianCount: gaussianCount, bands: bands,
                extended: hasExtension, kind: kind, deltaMode: deltaMode,
                referenceOffset: referenceOffset, keyframeOffset: keyframeOffset, depth: depth,
                liveCount: liveCount))
    }
    return out
}

public func chunkIndexEntries(_ bytes: [UInt8], _ walk: Walk) -> [IndexEntry] {
    (try? chunkIndexEntries(ToolReader(InMemoryReader(bytes)), walk)) ?? []
}

struct HeaderDispatch {
    let keyframeDelta: Bool
    let durationSec: Double
    let gaussianCount: UInt64
    let shDegree: UInt8
    let flags: UInt8
    let hasAudio: Bool
    let temporalModelOffset: UInt64
}

func headerDispatch(_ source: ToolReader, _ walk: Walk) throws -> HeaderDispatch? {
    guard let frame = walk.firstIntact(Opcode.header) else { return nil }
    let content = frame.offset + recordHeaderSize
    var relative: UInt64 = 0

    func stringLength() throws -> UInt64? {
        guard relative <= frame.length, frame.length - relative >= 4 else { return nil }
        let field = try source.exactly(
            offset: content + relative, count: 4, record: "Header string length")
        let length = UInt64(readU32(field, at: 0) ?? 0)
        relative += 4
        guard length <= frame.length - relative else { return nil }
        return length
    }

    guard let profileLength = try stringLength() else { return nil }
    relative += profileLength
    guard let libraryLength = try stringLength() else { return nil }
    relative += libraryLength

    let fixed: UInt64 = 24
    guard relative <= frame.length, frame.length - relative >= fixed else { return nil }
    let fixedBytes = try source.exactly(
        offset: content + relative, count: Int(fixed), record: "Header fixed fields")
    guard let durationSec = readF64(fixedBytes, at: 0),
        let gaussianCount = readU64(fixedBytes, at: 8)
    else { return nil }
    relative += fixed
    guard let modelLength = try stringLength() else { return nil }
    let modelOffset = content + relative
    guard modelLength <= frame.length - relative else { return nil }
    let model = try source.exactly(
        offset: modelOffset, count: Int(modelLength), record: "Header temporal_model")
    relative += modelLength
    let afterModel: UInt64 = 48 + 2
    guard relative <= frame.length, frame.length - relative >= afterModel else { return nil }
    let degreeAndFlags = try source.exactly(
        offset: content + relative + 48, count: 2, record: "Header sh_degree and flags")
    guard degreeAndFlags[0] <= 3 else {
        throw FourDGSError.malformed(
            offset: Int64(clamping: content + relative + 48), record: "Header",
            field: "sh_degree", reason: "declares \(degreeAndFlags[0]); expected 0 through 3")
    }
    let expected = Array("keyframe-delta".utf8)
    return HeaderDispatch(
        keyframeDelta: model == expected, durationSec: durationSec,
        gaussianCount: gaussianCount, shDegree: degreeAndFlags[0],
        flags: degreeAndFlags[1], hasAudio: degreeAndFlags[1] & 1 != 0,
        temporalModelOffset: modelOffset)
}

func isKeyframeDelta(_ source: ToolReader, _ walk: Walk) throws -> Bool {
    try headerDispatch(source, walk)?.keyframeDelta ?? false
}

public struct SummaryDeclaration {
    public let start: UInt64
    public let offsetStart: UInt64
    public let crc: UInt32
    public let end: UInt64
}

func summaryDeclaration(_ source: ToolReader, _ walk: Walk) throws -> SummaryDeclaration? {
    guard let frame = walk.firstIntact(Opcode.footer) else { return nil }
    let fields: UInt64 = 20
    let content = frame.offset + recordHeaderSize
    guard frame.length >= fields else {
        throw FourDGSError.malformed(
            offset: Int64(clamping: frame.offset), record: "Footer", field: "fixed fields",
            reason: "the record has \(frame.length) bytes; expected at least \(fields)")
    }
    let bytes = try source.exactly(offset: content, count: Int(fields), record: "Footer")
    guard let start = readU64(bytes, at: 0),
        let offsetStart = readU64(bytes, at: 8), let crc = readU32(bytes, at: 16)
    else { return nil }
    // §5.2: `summary_start` 0 is the file saying it has no summary, and that settles it.
    // Accepting a declaration whenever `summary_offset_start` happened to be nonzero gave
    // back a range of `0..<footerOffset` — every record in the file, the magic and the
    // Header included, read as "inside the summary" and fed to the CRC as though the
    // Footer had named them.
    guard start != 0 else { return nil }
    return SummaryDeclaration(
        start: start, offsetStart: offsetStart, crc: crc, end: frame.offset)
}

public func summaryDeclaration(_ bytes: [UInt8], _ walk: Walk) -> SummaryDeclaration? {
    try? summaryDeclaration(ToolReader(InMemoryReader(bytes)), walk)
}

public struct Coverage {
    public let start: UInt64
    public let end: UInt64
    public let ok: Bool

    public static func cell(_ coverage: Coverage?, at: UInt64, total: UInt64) -> String {
        guard let coverage else { return "-" }
        let (end, overflow) = at.addingReportingOverflow(total)
        guard !overflow, at >= coverage.start, end <= coverage.end else { return "-" }
        return coverage.ok ? "ok" : "MISMATCH"
    }
}

func coverage(_ source: ToolReader, _ walk: Walk) throws -> Coverage? {
    guard let declared = try summaryDeclaration(source, walk), declared.crc != 0,
        declared.start <= declared.end, declared.end <= walk.size
    else { return nil }

    let block = 64 * 1024
    var crc: UInt32 = 0xFFFF_FFFF
    var at = declared.start
    while at < declared.end {
        let remaining = declared.end - at
        let count = Int(min(UInt64(block), remaining))
        let bytes = try source.exactly(offset: at, count: count, record: "summary checksum")
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (0xEDB8_8320 ^ (crc >> 1)) : (crc >> 1)
            }
        }
        at += UInt64(count)
    }
    return Coverage(
        start: declared.start, end: declared.end, ok: (crc ^ 0xFFFF_FFFF) == declared.crc)
}

public func coverage(_ bytes: [UInt8], _ walk: Walk) -> Coverage? {
    try? coverage(ToolReader(InMemoryReader(bytes)), walk)
}

public struct ChunkRefusal {
    public let error: FourDGSError
    public let site: Site?
}

func scanChunks(_ reader: SceneReader, index: [IndexEntry]) -> ChunkRefusal? {
    let chunks = reader.scene.chunkIntervals.count
    guard chunks > 0, reader.scene.isIndexed else {
        return nil
    }
    for i in 0..<chunks {
        do {
            _ = try reader.chunk(i)
        } catch {
            return ChunkRefusal(error: asFourDGS(error), site: refusingRecord(reader, i, index))
        }
    }
    return nil
}

private func refusingRecord(_ reader: SceneReader, _ i: Int, _ index: [IndexEntry]) -> Site? {
    guard i < index.count else { return nil }
    let entry = index[i]
    let chunk = Site(offset: entry.offset, what: "the Chunk record at index entry \(i)")
    guard (try? reader.chunk(i, options: DecodeOptions(bandCap: 0))) != nil else { return chunk }
    for band in entry.bands.sorted(by: { $0.band < $1.band }) {
        if (try? reader.chunk(i, options: DecodeOptions(bandCap: Int(band.band)))) == nil {
            return Site(
                offset: band.offset,
                what:
                    "the SH Band Stream for band \(band.band) of the Chunk at index entry \(i)")
        }
    }
    return chunk
}
