// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Structural validation.
///
/// This is what makes a third-party encoder possible: a way to find out *why* a file is wrong
/// that does not involve reading someone else's decoder. Every finding names the record, the
/// field and what was expected.
///
/// The findings, their severities and their wording are `python/fourdgs/fourdgs/validate.py`'s.
/// Two validators that disagree about whether a file conforms are worse than one, so where the
/// two differ the Python module is the reference and this is the bug.
///
/// **What this validator does not check, and why.** The Python and Rust validators parse every
/// record's body and check its fields — the Header's gaussian count against the chunks, each
/// Audio Source's pose and timing, every quantization step for finiteness. This one does not,
/// because the Swift package is a binding: full record parsing and gaussian reconstruction go
/// through `CoreSeam.swift`, and writing those parsers here would make the tool a second decoder
/// that could disagree with the one it ships beside. The checks below therefore read only bounded
/// structural fields — framing, fixed index and state-record headers, the summary checksum — plus
/// everything the reader itself decides, which is where the six named refusals live.
///
/// The consequence is worth stating plainly: on a file this tool calls valid, Python may still
/// have something to say. It reports a subset of Python's findings and never a finding Python
/// contradicts, which is the property that matters — a validator that is quieter is a gap, and
/// one that disagrees is a bug.
///
/// Three things it does that the Python tool does not:
///
/// * **It prints the refusal identifier and the byte.** The finding lines themselves match
///   Python's word for word; the identifier goes on a line of its own beneath the finding it
///   belongs to. Python's exceptions carry the same `code` — its CLI simply does not print it.
/// * **It decodes every physical Chunk.** A framing walk steps over a chunk by its declared length,
///   so a fault inside its streams is invisible to it; two of the invalid corpus's seven files are
///   exactly that, and Python calls them clean. Indexed chunks use their ordinary ranges. A chunk
///   absent from the index is exposed to the streamed core in a one-chunk virtual file, so the
///   working set stays bounded by that chunk.
/// * **It recognizes `keyframe-delta`.** Python reports a conforming keyframe-delta file as
///   invalid, because its structural checks assume the gaussian-birth chunk shape. This tool
///   validates its timeline tiling, backward reference chains, exact depth, keyframe ancestry and
///   every field duplicated between the index and a Delta Chunk. Its current ABI has no ranged
///   composition entry point, so bounded validation does not repeat the core's state composition.

import FourDGS

public enum Severity: Int, Comparable {
    case note
    case warning
    case error

    /// `note`, `warning`, `error` — the prefix a finding is printed under.
    public var name: String {
        switch self {
        case .note: return "note"
        case .warning: return "warning"
        case .error: return "error"
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One thing wrong with a file, and — when the SDK named it — which refusal it is.
public struct Finding {
    public let severity: Severity
    /// Word for word what the Python validator prints for the same bytes.
    public let message: String
    /// The refusal identifier and the byte it fired at, for the findings that have one. Most do
    /// not: "first record is Footer; the Header must come first" is a rule this validator checks
    /// itself, not a refusal the reader raised, and the refusal table does not name it.
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

    /// An error the reader raised, carrying its identifier and the byte if it has one.
    ///
    /// `prefix` is what the message is introduced with, so the sentence stays the one the other
    /// validators print; the identifier arrives on its own line and changes nothing about it.
    mutating func refused(_ prefix: String, _ error: FourDGSError, _ walk: Walk?, _ site: Site?) {
        push(.error, prefix + sentence(error), describe(error, walk: walk, site: site))
    }
}

/// One original byte range in the small virtual file used to decode one physical Chunk.
private struct SourceSlice {
    let offset: UInt64
    let length: UInt64
}

/// A concatenation of original byte ranges, without copying them.
///
/// Validation gives the streamed core the magic, the active Header/Quantization/Window Table and
/// one Chunk. The virtual file deliberately ends there, so truncation recovery returns that one
/// decoded chunk. Memory is therefore bounded by one chunk even when the original has no index.
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
            guard let readOffset = Int64(exactly: slice.offset + within) else {
                throw FourDGSError.invalidRange(offset: Int64.max, count: Int(take))
            }
            let bytes = try source.read(offset: readOffset, count: Int(take))
            out.append(contentsOf: bytes)
            logical += UInt64(bytes.count)
            remaining -= UInt64(bytes.count)
            if UInt64(bytes.count) != take || remaining == 0 { break }
        }
        return out
    }
}

/// The fields duplicated between a physical state record and its Chunk Index entry.
private struct ChunkFields {
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

private func singleChunkReader(
    _ source: ToolReader, header: Frame, quantization: Frame, windowTable: Frame?, chunk: Frame
) -> SlicedReader {
    var slices = [
        SourceSlice(offset: 0, length: UInt64(magic.count)),
        SourceSlice(offset: header.offset, length: header.total),
        SourceSlice(offset: quantization.offset, length: quantization.total),
    ]
    if let windowTable {
        slices.append(SourceSlice(offset: windowTable.offset, length: windowTable.total))
    }
    slices.append(SourceSlice(offset: chunk.offset, length: chunk.total))
    return SlicedReader(source: source, slices: slices)
}

private func isChunkRefusal(_ error: FourDGSError) -> Bool {
    error.refusalCode == .unknownStreamCodec || error.refusalCode == .windowIndexOutOfRange
}

/// Match the index against the physical framing, validate the summary's members, and decode every
/// gaussian-birth Chunk even when the index omits it. The second walk retains no frames; its only
/// growing structures are keyed by the already-small index.
private func validatePhysicalRecords(
    _ source: ToolReader, _ walked: Walk, index: [IndexEntry], keyframeDelta: Bool,
    summary: SummaryDeclaration?, indexBoundsSafe: Bool, report: inout Report
) -> PhysicalValidation {
    var result = PhysicalValidation(indexSafe: indexBoundsSafe)
    var scanReport = Report()
    var byOffset: [UInt64: [Int]] = [:]
    for (i, entry) in index.enumerated() { byOffset[entry.offset, default: []].append(i) }

    var header: Frame?
    var quantization: Frame?
    var windowTable: Frame?
    var firstChunkRefusal: (FourDGSError, Site)?
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

                guard frame.opcode == Opcode.chunk || frame.opcode == Opcode.deltaChunk else {
                    return
                }
                let legalPhysicalKind =
                    frame.opcode == Opcode.chunk || (keyframeDelta && frame.opcode == Opcode.deltaChunk)
                guard legalPhysicalKind else { return }

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

                if keyframeDelta && !entries.isEmpty {
                    do {
                        if let fields = try chunkFields(source, frame) {
                            result.fields[frame.offset] = fields
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

                guard !keyframeDelta, firstChunkRefusal == nil, frame.opcode == Opcode.chunk,
                    let header, let quantization
                else { return }
                do {
                    _ = try SceneReader(
                        singleChunkReader(
                            source, header: header, quantization: quantization,
                            windowTable: windowTable, chunk: frame),
                        path: .streamed)
                } catch {
                    let refusal = asFourDGS(error)
                    if isChunkRefusal(refusal) {
                        firstChunkRefusal = (
                            refusal,
                            Site(
                                offset: frame.offset,
                                what: "the physical Chunk record at byte \(frame.offset)")
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
    report.findings.append(contentsOf: scanReport.findings)
    if let firstChunkRefusal {
        report.refused(
            "a physical chunk does not decode: ", firstChunkRefusal.0, walked,
            firstChunkRefusal.1)
        result.chunkRefused = true
    }
    return result
}

private func validateKeyframeDeltaIndex(
    _ index: [IndexEntry], fields: [UInt64: ChunkFields], report: inout Report
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

        guard entry.kind == 1 else { continue }
        if entry.referenceOffset >= entry.offset {
            report.error(
                "the chunk at \(entry.offset) references \(entry.referenceOffset), which is not "
                    + "behind it; references point backwards only")
            continue
        }
        var current = entry
        var deltaCount = 0
        var broken = false
        while current.kind != 0 {
            guard current.referenceOffset < current.offset else {
                report.error(
                    "the chunk at \(current.offset) references \(current.referenceOffset), which "
                        + "is not behind it; references point backwards only")
                broken = true
                break
            }
            guard let candidates = byOffset[current.referenceOffset], candidates.count == 1 else {
                report.error(
                    "the chunk at \(current.offset) references \(current.referenceOffset), which "
                        + "the index does not name exactly once")
                broken = true
                break
            }
            let reference = index[candidates[0]]
            if current.deltaMode == 0 && current.referenceOffset != current.keyframeOffset {
                report.error(
                    "chunk index entry \(i) uses keyframe-referenced delta_mode 0 but references "
                        + "\(current.referenceOffset); expected keyframe_offset "
                        + "\(current.keyframeOffset)")
                broken = true
                break
            }
            if current.deltaMode == 1 && reference.t1 != current.t0 {
                report.error(
                    "chunk index entry \(i) uses chained delta_mode 1 but references interval "
                        + "[\(reference.t0), \(reference.t1)); expected the state immediately "
                        + "preceding t0 \(current.t0)")
                broken = true
                break
            }
            if let physical = fields[current.offset], let referencePhysical = fields[reference.offset],
                physical.level != referencePhysical.level
            {
                report.error(
                    "the DeltaChunk at byte \(current.offset) has level \(physical.level), but its "
                        + "reference at byte \(reference.offset) has level "
                        + "\(referencePhysical.level); expected equal levels")
            }
            current = reference
            deltaCount += 1
            if deltaCount > index.count {
                report.error("the chain from chunk \(entry.offset) does not reach a keyframe")
                broken = true
                break
            }
        }
        guard !broken else { continue }
        if deltaCount != Int(entry.depth) {
            report.error(
                "the chunk at \(entry.offset) declares depth \(entry.depth), but its chain walks "
                    + "\(deltaCount) delta chunks; the index and the file disagree about the cost "
                    + "of this seek")
        }
        if entry.keyframeOffset != current.offset {
            report.error(
                "the chunk at \(entry.offset) declares keyframe_offset "
                    + "\(entry.keyframeOffset), but its chain reaches keyframe \(current.offset)")
        }
    }
}

/// Every check, over one size-and-range transport.
func validate(_ source: ToolReader) -> Report {
    var report = Report()

    // Framing first, and for two reasons: it refuses a file that is not ours before anything
    // reads a byte as an opcode, and it is what gives every later refusal a byte to point at.
    var firstOpcode: UInt8?
    var lastOpcode: UInt8?
    var hasHeader = false
    var hasQuantization = false
    var hasFooter = false
    // Two are enough to preserve the refusal-placement rule: one can be placed, more than one is
    // ambiguous. Footer content is read only from the first. Chunk Index frames are the format's
    // small seek index; every unrelated top-level frame is consumed and immediately discarded.
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
                    // The reserved tail of the provenance family is spoken for, so this is a
                    // future-revision record rather than a byte the reader cannot account for.
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

    // Report the cut before any early return. In particular, a file cut inside its first record
    // has no intact first opcode, but the walk still knows that record's byte, kind, declared
    // length and the resource size — the useful diagnosis must not be hidden by "no records".
    if let cut = walked.cut {
        report.note(
            "the file is cut at byte \(commas(cut.at)): \(cut.reason). The \(walked.intact) "
                + "complete records before it are intact, and a streamed reader recovers them")
    }

    // Only whole records set these values: a record the file was cut inside is reported by the
    // note above, and counting it as present would say a Footer exists before its bytes do.
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

    // Which chunk shape the rest of this validator is entitled to assume. A `keyframe-delta`
    // file's Chunks are keyframes and its Delta Chunks are differences against them, so the index
    // check below is about the gaussian-birth shape and about nothing else. Read from the Header
    // rather than guessed from the records, because a file that carries Delta Chunks and does not
    // say so is itself a fault.
    //
    // The two length-prefixed strings before this field are skipped by their declared lengths;
    // only four-byte lengths and the fourteen-byte dispatch value are read. A fixed prefix is not
    // sufficient because a conforming profile or library name can put this field arbitrarily far
    // into the Header.
    let keyframeDelta: Bool
    do {
        keyframeDelta = try isKeyframeDelta(source, walked)
    } catch {
        report.refused("", asFourDGS(error), walked, nil)
        return report
    }

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
        // A `keyframe-delta` file indexes both kinds: a Chunk is a keyframe and a Delta Chunk is
        // a difference against one, and an index that could only name the former could not seek
        // the model at all.
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
        source, walked, index: index, keyframeDelta: keyframeDelta, summary: summary,
        indexBoundsSafe: indexBoundsSafe, report: &report)
    if keyframeDelta {
        validateKeyframeDeltaIndex(index, fields: physical.fields, report: &report)
    } else {
        checkGaussianBirth(
            source, walked, index, indexSafe: physical.indexSafe,
            chunkAlreadyRefused: physical.chunkRefused, &report)
    }

    return report
}

/// The in-memory convenience used by parser tests and callers that already own their bytes.
public func validate(_ bytes: [UInt8]) -> Report {
    validate(ToolReader(InMemoryReader(bytes)))
}

/// The two checks only a reader can perform: open the file, then decode it.
///
/// Opening it the way a seeking client would is where the front-matter refusals fire — an
/// unimplemented temporal model, an unimplemented quantization scheme. Decoding the chunks is
/// where the rest do, and there is no substitute for it: the framing walk steps over a chunk by
/// its declared length, so an unimplemented stream codec and an out-of-range window index are
/// both invisible to everything before this point. Both are in the invalid corpus.
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
        // A file that will not open will not decode either, and the second error would say the
        // same thing about the same byte.
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
        // Not the file's fault, and not a refusal. See ``exitTool``.
        err.line("4dgs: \(path): \(sentence(asFourDGS(error)))")
        return exitTool
    }
    let report = validate(source)
    for finding in report.findings {
        out.line("\(finding.severity.name): \(finding.message)")
        // Indented, and with a prefix of its own, so that a caller filtering the findings on
        // `error:`/`warning:`/`note:` — which is how the validators are compared — sees exactly
        // what it saw before.
        if let refusal = finding.refusal { out.line("  \(refusal)") }
    }
    if !report.ok {
        err.line("INVALID")
        return exitFailed
    }
    out.line(report.findings.isEmpty ? "valid" : "valid (with notes)")
    // The one deliberate divergence from the Python tool, which exits 0 here, and the Rust and
    // C++ tools' too. A warning a script cannot see is a warning nobody acts on, so it gets its
    // own code.
    return report.worst == .warning ? exitWarnings : exitOk
}
