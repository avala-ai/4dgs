// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FourDGS
import CFourDGS
import XCTest

@testable import FourDGSTool

private struct Runs {
    let code: Int32
    let out: String
    let err: String
}

private func runTool(_ arguments: [String]) -> Runs {
    let out = TextBuffer()
    let err = TextBuffer()
    let code = run(arguments, out: out, err: err)
    return Runs(code: code, out: out.text, err: err.text)
}

private let provenanceVariant = "TenWindows-UseChunkIndex-UseCrc-WithFrame-WithRig-WithSensors.4dgs"

private func corpusDirectory() -> URL {
    if let fromEnvironment = ProcessInfo.processInfo.environment["FOURDGS_CORPUS"] {
        return URL(fileURLWithPath: fromEnvironment)
    }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { root.deleteLastPathComponent() }
    return root.appendingPathComponent("tests/conformance/data")
}

private func requireCorpus() throws {
    let invalid = corpusDirectory().appendingPathComponent("invalid")
    if FileManager.default.fileExists(atPath: invalid.path) { return }
    if ProcessInfo.processInfo.environment["CI"] != nil {
        XCTFail("the corpus is missing; run tests/conformance/generate.py")
        return
    }
    throw XCTSkip("no corpus; run tests/conformance/generate.py first")
}

private func variants(_ directory: URL) -> [URL] {
    let found = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return
        found
        .filter { $0.hasSuffix(".4dgs") }
        .sorted()
        .map { directory.appendingPathComponent($0) }
}

private func readFixture(_ url: URL) throws -> [UInt8] {
    [UInt8](try Data(contentsOf: url))
}

private func writeU64(_ value: UInt64, into bytes: inout [UInt8], at offset: UInt64) {
    for i in 0..<8 { bytes[Int(offset) + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
}

private func writeU32(_ value: UInt32, into bytes: inout [UInt8], at offset: UInt64) {
    for i in 0..<4 { bytes[Int(offset) + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
}

private func littleU32(_ value: UInt32) -> [UInt8] {
    (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
}

private func littleU16(_ value: UInt16) -> [UInt8] {
    (0..<2).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
}

private func littleU64(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
}

private func deflated(_ bytes: [UInt8]) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: Int(compressBound(uLong(bytes.count))))
    var length = uLongf(output.count)
    let status = bytes.withUnsafeBytes { input in
        output.withUnsafeMutableBytes { destination in
            compress2(
                destination.bindMemory(to: Bytef.self).baseAddress, &length,
                input.bindMemory(to: Bytef.self).baseAddress, uLong(bytes.count), Z_BEST_COMPRESSION)
        }
    }
    precondition(status == Z_OK)
    output.removeLast(output.count - Int(length))
    return output
}

private func compressedDeltaRecord() -> [UInt8] {
    let records = [UInt8](repeating: 0, count: 24)  // three empty length-framed groups
    let compressed = deflated(records)
    var body = littleU64(0) + littleU64(1.0.bitPattern) + littleU32(0) + [UInt8(1)]
    body += littleU64(0) + littleU64(0) + littleU16(1)
    body += littleU32(0) + littleU32(0) + littleU32(0)
    body += littleU32(7) + Array("deflate".utf8)
    body += littleU64(UInt64(records.count)) + littleU64(UInt64(compressed.count)) + compressed
    return [Opcode.deltaChunk] + littleU64(UInt64(body.count)) + body
}

private func withTemporaryFile<T>(_ bytes: [UInt8], _ body: (String) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".4dgs")
    try Data(bytes).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url.path)
}

private final class RecordingReader: ByteRangeReader {
    let bytes: [UInt8]
    private(set) var largestRead = 0
    private(set) var ranges: [Range<Int>] = []

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    func byteCount() throws -> Int64 { Int64(bytes.count) }

    func read(offset: Int64, count: Int) throws -> [UInt8] {
        largestRead = max(largestRead, count)
        let start = min(Int(clamping: offset), bytes.count)
        let end = min(start + count, bytes.count)
        ranges.append(start..<end)
        return Array(bytes[start..<end])
    }
}

private func expectedRefusal(_ variant: URL) -> String? {
    let json = variant.deletingPathExtension().appendingPathExtension("json")
    guard let data = FileManager.default.contents(atPath: json.path),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object["refused"] as? String
}

final class ValidateTests: XCTestCase {

    func testEveryInvalidVariantIsRefusedByItsOwnIdentifier() throws {
        try requireCorpus()
        let files = variants(corpusDirectory().appendingPathComponent("invalid"))
        XCTAssertEqual(files.count, 7)
        for file in files {
            let code = try XCTUnwrap(expectedRefusal(file), "\(file.lastPathComponent)")
            let result = runTool(["validate", file.path])
            XCTAssertEqual(result.code, exitFailed, "\(file.lastPathComponent)")
            XCTAssertTrue(
                result.out.contains("refusal \(code) at byte "),
                "\(file.lastPathComponent) said: \(result.out)")
        }
    }

    func testAConformingCaptureIsValid() throws {
        try requireCorpus()
        let file = corpusDirectory().appendingPathComponent(provenanceVariant)
        let result = runTool(["validate", file.path])
        XCTAssertEqual(result.code, exitOk, result.out)
        XCTAssertTrue(result.out.contains("valid"))
        XCTAssertFalse(result.out.contains("unknown record"))
        XCTAssertFalse(result.out.contains("error:"))
    }

    func testAConformingKeyframeDeltaFileIsValid() throws {
        try requireCorpus()
        let files = variants(corpusDirectory().appendingPathComponent("keyframe"))
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let result = runTool(["validate", file.path])
            XCTAssertEqual(result.code, exitOk, "\(file.lastPathComponent) said: \(result.out)")
            XCTAssertFalse(result.out.contains("error:"), result.out)
            XCTAssertTrue(result.out.contains("valid"), result.out)
            XCTAssertEqual(result.err, "")
        }
    }

    func testEveryValidVariantIsValid() throws {
        try requireCorpus()
        let files =
            variants(corpusDirectory()) + variants(corpusDirectory().appendingPathComponent("object"))
        XCTAssertGreaterThanOrEqual(files.count, 40)
        for file in files {
            let result = runTool(["validate", file.path])
            XCTAssertTrue(
                result.code == exitOk || result.code == exitWarnings,
                "\(file.lastPathComponent) said: \(result.out)")
        }
    }

    func testABandThatWillNotDecodeIsRefusedAndPlacedAtItsOwnRecord() throws {
        try requireCorpus()
        let variant = "MixedLifetimes-SHDegree3-UseChunkIndex-UseCrc.4dgs"
        var bytes = try readFixture(corpusDirectory().appendingPathComponent(variant))
        XCTAssertTrue(validate(bytes).ok, "the unpatched variant is a conforming file")

        let walked = try walk(bytes)
        let bands = walked.records.filter { $0.opcode == 0x07 }
        XCTAssertGreaterThanOrEqual(bands.count, 3)
        let band = bands[1]
        bytes[Int(band.offset + recordHeaderSize) + 4] = 9

        let report = validate(bytes)
        XCTAssertFalse(report.ok, "a band that does not decode is not a valid file")
        let refusal = try XCTUnwrap(report.findings.compactMap(\.refusal).first)
        XCTAssertEqual(refusal.code, .unknownStreamCodec)
        XCTAssertEqual(refusal.site?.offset, band.offset)
        XCTAssertEqual(
            refusal.site?.what, "the SH Band Stream for band 2 of the Chunk at index entry 0")
    }

    func testACutFileReportsTheIntactPrefixAndTheByte() throws {
        try requireCorpus()
        let bytes = try readFixture(corpusDirectory().appendingPathComponent(provenanceVariant))
        let whole = try walk(bytes)
        let cutBytes = Array(bytes.prefix(bytes.count / 2))
        let cut = try walk(cutBytes)
        let where_ = try XCTUnwrap(cut.cut)
        XCTAssertLessThan(where_.at, UInt64(cutBytes.count))
        XCTAssertFalse(cut.trailingMagic)
        XCTAssertFalse(cut.records.isEmpty)
        XCTAssertLessThan(cut.records.count, whole.records.count)
        XCTAssertEqual(cut.intact, cut.records.count - 1)

        let report = validate(cutBytes)
        XCTAssertFalse(report.ok)
        XCTAssertTrue(
            report.findings.contains {
                $0.severity == .note && $0.message.hasPrefix("the file is cut at byte ")
            }, "\(report.findings.map(\.message))")
    }

    func testACutInsideTheFirstRecordReportsItsFrame() {
        let bytes = magic + [Opcode.header] + littleU64(32) + [0xAA] + magic
        let report = validate(bytes)

        XCTAssertFalse(report.ok)
        XCTAssertTrue(
            report.findings.contains {
                $0.severity == .note
                    && $0.message.contains("the Header record declares 32 bytes")
                    && $0.message.contains("past the end of a \(bytes.count)-byte file")
            }, "\(report.findings.map(\.message))")
    }

    func testAnIndexOffsetAtEndOfFileIsDiagnosed() throws {
        try requireCorpus()
        var bytes = try readFixture(corpusDirectory().appendingPathComponent(provenanceVariant))
        let walked = try walk(bytes)
        let frame = try XCTUnwrap(walked.firstIntact(Opcode.chunkIndex))
        let content = frame.offset + recordHeaderSize
        writeU64(UInt64(bytes.count), into: &bytes, at: content + 16)
        writeU64(0, into: &bytes, at: content + 24)

        let report = validate(bytes)
        XCTAssertTrue(
            report.findings.contains {
                $0.message == "chunk index entry 0 points past the end of the file"
            }, "\(report.findings.map(\.message))")
    }

    func testAnIndexedLengthMustEqualThePhysicalFrame() throws {
        try requireCorpus()
        var bytes = try readFixture(corpusDirectory().appendingPathComponent(provenanceVariant))
        let walked = try walk(bytes)
        let frame = try XCTUnwrap(walked.firstIntact(Opcode.chunkIndex))
        let entry = try XCTUnwrap(chunkIndexEntries(bytes, walked).first)
        writeU64(entry.length + 1, into: &bytes, at: frame.offset + recordHeaderSize + 24)

        let report = validate(bytes)
        XCTAssertFalse(report.ok)
        XCTAssertTrue(
            report.findings.contains {
                $0.message.contains("chunk index entry 0 declares \(entry.length + 1) bytes")
                    && $0.message.contains("its framed length is \(entry.length) bytes")
            }, "\(report.findings.map(\.message))")
    }

    func testAnIndexedBandLengthMustEqualThePhysicalFrame() throws {
        try requireCorpus()
        let variant = "MixedLifetimes-SHDegree3-UseChunkIndex-UseCrc.4dgs"
        var bytes = try readFixture(corpusDirectory().appendingPathComponent(variant))
        let walked = try walk(bytes)
        let frames = walked.records.filter { $0.opcode == Opcode.chunkIndex }
        let entries = chunkIndexEntries(bytes, walked)
        let entryIndex = try XCTUnwrap(entries.firstIndex { !$0.bands.isEmpty })
        let band = entries[entryIndex].bands[0]
        XCTAssertEqual(frames.count, entries.count)
        writeU64(
            band.length + 1, into: &bytes,
            at: frames[entryIndex].offset + recordHeaderSize + 40 + 9)

        let report = validate(bytes)
        XCTAssertFalse(report.ok)
        XCTAssertTrue(
            report.findings.contains {
                $0.message.contains(
                    "chunk index entry \(entryIndex) declares \(band.length + 1) bytes")
                    && $0.message.contains("its framed length is \(band.length) bytes")
            }, "\(report.findings.map(\.message))")
    }

    func testAChunkAbsentFromTheIndexIsStillDecoded() throws {
        try requireCorpus()
        let file = corpusDirectory().appendingPathComponent("invalid/UnknownStreamCodec.4dgs")
        var bytes = try readFixture(file)
        let walked = try walk(bytes)
        let frames = walked.records.filter { $0.opcode == Opcode.chunkIndex }
        let entries = chunkIndexEntries(bytes, walked)
        XCTAssertGreaterThanOrEqual(entries.count, 2)
        writeU64(
            entries[1].offset, into: &bytes,
            at: frames[0].offset + recordHeaderSize + 16)

        let report = validate(bytes)
        XCTAssertFalse(report.ok)
        XCTAssertTrue(
            report.findings.contains {
                $0.message
                    == "the Chunk record at byte \(entries[0].offset) is absent from the Chunk Index"
            }, "\(report.findings.map(\.message))")
        XCTAssertTrue(
            report.findings.compactMap(\.refusal).contains { $0.code == .unknownStreamCodec },
            "\(report.findings.map(\.message))")
    }

    func testEveryPhysicalChunkDecodeFailureIsInvalid() throws {
        try requireCorpus()
        var bytes = try readFixture(
            corpusDirectory().appendingPathComponent("TenWindows-UseCrc.4dgs"))
        let chunk = try XCTUnwrap(try walk(bytes).firstIntact(Opcode.chunk))
        bytes[Int(chunk.offset + recordHeaderSize + 44)] = 99

        let report = validate(bytes)
        XCTAssertFalse(report.ok)
        XCTAssertTrue(
            report.findings.contains { $0.severity == .error },
            "\(report.findings.map(\.message))")
    }

    func testSummaryRejectsANonSummaryRecordEvenWithAMatchingCRC() throws {
        try requireCorpus()
        let variant =
            "TenWindows-UseChunkIndex-UseChunks-UseCrc-UseStatistics-UseSummaryOffset.4dgs"
        var bytes = try readFixture(corpusDirectory().appendingPathComponent(variant))
        let walked = try walk(bytes)
        let statistics = try XCTUnwrap(walked.firstIntact(Opcode.statistics))
        let footer = try XCTUnwrap(walked.firstIntact(Opcode.footer))
        let summary = try XCTUnwrap(summaryDeclaration(bytes, walked))
        bytes[Int(statistics.offset)] = Opcode.privateStart
        let checksum = crc32(bytes[Int(summary.start)..<Int(summary.end)])
        writeU32(checksum, into: &bytes, at: footer.offset + recordHeaderSize + 16)

        let report = validate(bytes)
        XCTAssertFalse(report.ok)
        XCTAssertFalse(report.findings.contains { $0.message.hasPrefix("summary CRC mismatch") })
        XCTAssertTrue(
            report.findings.contains {
                $0.message
                    == "the Footer's summary contains Private(0x80) at byte \(statistics.offset); "
                    + "expected only ChunkIndex, Statistics, or SummaryOffset records"
            }, "\(report.findings.map(\.message))")
    }

    func testSummaryStructureIsCheckedWhenItsCRCIsZero() throws {
        try requireCorpus()
        let variant =
            "TenWindows-UseChunkIndex-UseChunks-UseCrc-UseStatistics-UseSummaryOffset.4dgs"
        var bytes = try readFixture(corpusDirectory().appendingPathComponent(variant))
        let walked = try walk(bytes)
        let statistics = try XCTUnwrap(walked.firstIntact(Opcode.statistics))
        let footer = try XCTUnwrap(walked.firstIntact(Opcode.footer))
        bytes[Int(statistics.offset)] = Opcode.privateStart
        writeU32(0, into: &bytes, at: footer.offset + recordHeaderSize + 16)

        let report = validate(bytes)
        XCTAssertFalse(report.ok)
        XCTAssertFalse(report.findings.contains { $0.message.hasPrefix("summary CRC mismatch") })
        XCTAssertTrue(
            report.findings.contains {
                $0.message
                    == "the Footer's summary contains Private(0x80) at byte "
                    + "\(statistics.offset); expected only ChunkIndex, Statistics, or "
                    + "SummaryOffset records"
            }, "\(report.findings.map(\.message))")
    }

    func testGaussianBirthRejectsAPhysicalDeltaChunk() throws {
        try requireCorpus()
        var bytes = try readFixture(corpusDirectory().appendingPathComponent(provenanceVariant))
        let walked = try walk(bytes)
        let chunk = try XCTUnwrap(walked.firstIntact(Opcode.chunk))
        bytes[Int(chunk.offset)] = Opcode.deltaChunk

        let report = validate(bytes)
        XCTAssertFalse(report.ok)
        XCTAssertTrue(
            report.findings.contains {
                $0.message
                    == "the gaussian-birth file contains DeltaChunk at byte \(chunk.offset); "
                    + "DeltaChunk belongs only to keyframe-delta"
            }, "\(report.findings.map(\.message))")
    }

    func testKeyframeDeltaIndexDiagnosticNamesBothLegalTargets() throws {
        try requireCorpus()
        let file = try XCTUnwrap(
            variants(corpusDirectory().appendingPathComponent("keyframe")).first)
        var bytes = try readFixture(file)
        let walked = try walk(bytes)
        let frame = try XCTUnwrap(walked.firstIntact(Opcode.chunkIndex))
        writeU64(8, into: &bytes, at: frame.offset + recordHeaderSize + 16)

        let report = validate(bytes)
        XCTAssertTrue(
            report.findings.contains {
                $0.message == "chunk index entry 0 does not point at a Chunk or DeltaChunk record"
            }, "\(report.findings.map(\.message))")
    }

    func testKeyframeDeltaIndexIntervalsMustTile() throws {
        try requireCorpus()
        let file = try XCTUnwrap(
            variants(corpusDirectory().appendingPathComponent("keyframe")).first)
        var bytes = try readFixture(file)
        let walked = try walk(bytes)
        let frames = walked.records.filter { $0.opcode == Opcode.chunkIndex }
        let entries = chunkIndexEntries(bytes, walked)
        XCTAssertGreaterThanOrEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy(\.extended))
        writeU64(
            entries[0].t0.bitPattern, into: &bytes,
            at: frames[1].offset + recordHeaderSize)

        let report = validate(bytes)
        XCTAssertTrue(
            report.findings.contains { $0.message.hasPrefix("state chunks overlap:") },
            "\(report.findings.map(\.message))")
    }

    func testKeyframeDeltaTimelineMustCoverTheHeaderDuration() throws {
        try requireCorpus()
        let file = try XCTUnwrap(
            variants(corpusDirectory().appendingPathComponent("keyframe")).first)
        let original = try readFixture(file)
        let walked = try walk(original)
        let frames = walked.records.filter { $0.opcode == Opcode.chunkIndex }
        let entries = chunkIndexEntries(original, walked)
        XCTAssertEqual(frames.count, entries.count)

        let first = try XCTUnwrap(entries.indices.min { entries[$0].t0 < entries[$1].t0 })
        let firstPhysical = try XCTUnwrap(
            walked.records.first { $0.offset == entries[first].offset })
        var lateStart = original
        writeU64(0.25.bitPattern, into: &lateStart, at: frames[first].offset + recordHeaderSize)
        writeU64(
            0.25.bitPattern, into: &lateStart,
            at: firstPhysical.offset + recordHeaderSize)
        let startReport = validate(lateStart)
        XCTAssertTrue(
            startReport.findings.contains {
                $0.message
                    == "state chunks start at 0.25; expected the keyframe-delta timeline to start at 0"
            }, "\(startReport.findings.map(\.message))")

        let last = try XCTUnwrap(entries.indices.max { entries[$0].t1 < entries[$1].t1 })
        let lastPhysical = try XCTUnwrap(
            walked.records.first { $0.offset == entries[last].offset })
        let earlyEnd = entries[last].t1 - 0.25
        var shortEnd = original
        writeU64(
            earlyEnd.bitPattern, into: &shortEnd,
            at: frames[last].offset + recordHeaderSize + 8)
        writeU64(
            earlyEnd.bitPattern, into: &shortEnd,
            at: lastPhysical.offset + recordHeaderSize + 8)
        let endReport = validate(shortEnd)
        XCTAssertTrue(
            endReport.findings.contains {
                $0.message
                    == "state chunks end at \(earlyEnd); expected Header duration_sec "
                    + "\(entries[last].t1)"
            }, "\(endReport.findings.map(\.message))")
    }

    func testKeyframeAndDeltaStreamsAreDecoded() throws {
        try requireCorpus()
        let file = corpusDirectory().appendingPathComponent(
            "keyframe/KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics.4dgs")
        let original = try readFixture(file)
        let walked = try walk(original)

        var keyframeBytes = original
        let keyframe = try XCTUnwrap(walked.firstIntact(Opcode.chunk))
        keyframeBytes[Int(keyframe.offset + recordHeaderSize + 44 + 3)] = 9
        let keyframeReport = validate(keyframeBytes)
        XCTAssertFalse(keyframeReport.ok)
        XCTAssertTrue(
            keyframeReport.findings.compactMap(\.refusal).contains {
                $0.code == .unknownStreamCodec
            }, "\(keyframeReport.findings.map(\.message))")

        var deltaBytes = original
        let delta = try XCTUnwrap(walked.firstIntact(Opcode.deltaChunk))
        var relative: UInt64 = 71
        var streamOffset: UInt64?
        for _ in 0..<3 {
            let length = try XCTUnwrap(
                readU64(deltaBytes, at: delta.offset + recordHeaderSize + relative))
            relative += 8
            if length >= 17 && streamOffset == nil {
                streamOffset = delta.offset + recordHeaderSize + relative
            }
            relative += length
        }
        let deltaStream = try XCTUnwrap(streamOffset)
        deltaBytes[Int(deltaStream + 3)] = 9
        let deltaReport = validate(deltaBytes)
        XCTAssertFalse(deltaReport.ok)
        XCTAssertTrue(
            deltaReport.findings.compactMap(\.refusal).contains {
                $0.code == .unknownStreamCodec
            }, "\(deltaReport.findings.map(\.message))")
    }

    func testCompressedDeltaRecordsAreInflatedBeforeGroupFraming() throws {
        var bytes = compressedDeltaRecord()
        let frame = Frame(opcode: Opcode.deltaChunk, offset: 0, length: UInt64(bytes.count - 9))
        let groups = try deltaGroups(ToolReader(InMemoryReader(bytes)), frame)
        XCTAssertEqual(groups.map(\.name), ["update", "birth", "death"])
        XCTAssertTrue(groups.allSatisfy { $0.length == 0 && $0.count == 0 })

        writeU64(0, into: &bytes, at: 9 + 51 + 4 + 7)
        XCTAssertThrowsError(try deltaGroups(ToolReader(InMemoryReader(bytes)), frame)) {
            XCTAssertTrue(sentence(asFourDGS($0)).contains("expands past the declared 0 bytes"))
        }
    }

    func testCompressedDeltaInflationUsesBoundedRangeReads() throws {
        let groupLength = 192 * 1024
        var value: UInt32 = 0x1234_5678
        var group: [UInt8] = []
        group.reserveCapacity(groupLength)
        for _ in 0..<groupLength {
            value = value &* 1_664_525 &+ 1_013_904_223
            group.append(UInt8(truncatingIfNeeded: value >> 24))
        }
        let records = littleU64(UInt64(group.count)) + group + littleU64(0) + littleU64(0)
        let compressed = deflated(records)
        XCTAssertGreaterThan(compressed.count, 64 * 1024)
        var body = littleU64(0) + littleU64(1.0.bitPattern) + littleU32(0) + [UInt8(1)]
        body += littleU64(0) + littleU64(0) + littleU16(1)
        body += littleU32(0) + littleU32(0) + littleU32(0)
        body += littleU32(7) + Array("deflate".utf8)
        body += littleU64(UInt64(records.count)) + littleU64(UInt64(compressed.count)) + compressed
        let bytes = [Opcode.deltaChunk] + littleU64(UInt64(body.count)) + body
        let recording = RecordingReader(bytes)
        let frame = Frame(opcode: Opcode.deltaChunk, offset: 0, length: UInt64(body.count))

        let groups = try deltaGroups(ToolReader(recording), frame)

        XCTAssertEqual(groups.first?.length, UInt64(groupLength))
        XCTAssertLessThanOrEqual(recording.largestRead, 64 * 1024)
        XCTAssertLessThan(recording.largestRead, compressed.count)
    }

    func testKeyframeDeltaDecodesIndexedSHBandStreams() throws {
        try requireCorpus()
        let file = corpusDirectory().appendingPathComponent(
            "MixedLifetimes-SHDegree3-UseChunkIndex-UseCrc.4dgs")
        var bytes = try readFixture(file)
        let walked = try walk(bytes)
        let dispatch = try XCTUnwrap(try headerDispatch(ToolReader(InMemoryReader(bytes)), walked))
        bytes.replaceSubrange(
            Int(dispatch.temporalModelOffset)..<Int(dispatch.temporalModelOffset + 14),
            with: "keyframe-delta".utf8)
        let band = try XCTUnwrap(walked.firstIntact(Opcode.shBandStream))
        bytes[Int(band.offset + recordHeaderSize + 4)] = 9

        let report = validate(bytes)
        XCTAssertTrue(
            report.findings.compactMap(\.refusal).contains { $0.code == .unknownStreamCodec },
            "\(report.findings.map(\.message))")
    }

    func testAnUndersizedChunkIndexIsMalformed() {
        var walked = Walk()
        walked.records = [Frame(opcode: Opcode.chunkIndex, offset: 8, length: 39)]
        XCTAssertThrowsError(try chunkIndexEntries(ToolReader(InMemoryReader([])), walked)) {
            XCTAssertTrue(sentence(asFourDGS($0)).contains("expected at least 40"))
        }
    }

    func testASecondHeaderCannotDisplaceKeyframeDispatch() throws {
        try requireCorpus()
        let file = try XCTUnwrap(
            variants(corpusDirectory().appendingPathComponent("keyframe")).first)
        var bytes = try readFixture(file)
        let walked = try walk(bytes)
        let header = try XCTUnwrap(walked.firstIntact(Opcode.header))
        let state = try XCTUnwrap(
            walked.records.first { $0.opcode == Opcode.chunk || $0.opcode == Opcode.deltaChunk })
        let copy = bytes[Int(header.offset)..<Int(header.offset + header.total)]
        bytes.insert(contentsOf: copy, at: Int(state.offset))
        XCTAssertFalse(validate(bytes).ok)

        let source = ToolReader(InMemoryReader(try readFixture(file)))
        let dispatch = try XCTUnwrap(try headerDispatch(source, walked))
        var malformedHeader = Array(copy)
        let model = Int(dispatch.temporalModelOffset - header.offset)
        malformedHeader.replaceSubrange(model..<(model + 14), with: "unknown-model!".utf8)
        var secondMalformedHeader = try readFixture(file)
        secondMalformedHeader.insert(contentsOf: malformedHeader, at: Int(state.offset))
        XCTAssertTrue(
            validate(secondMalformedHeader).findings.contains {
                $0.refusal?.code == .unknownTemporalModel
                    && $0.refusal?.site?.offset == state.offset
            })

        let quantization = try XCTUnwrap(walked.firstIntact(Opcode.quantization))
        var malformedQuantization = Array(
            try readFixture(file)[
                Int(quantization.offset)..<Int(quantization.offset + quantization.total)])
        let schemeLength = Int(try XCTUnwrap(readU32(malformedQuantization, at: recordHeaderSize)))
        malformedQuantization.replaceSubrange(
            Int(recordHeaderSize + 4)..<Int(recordHeaderSize + 4 + UInt64(schemeLength)),
            with: [UInt8](repeating: 0x78, count: schemeLength))
        var secondMalformedQuantization = try readFixture(file)
        secondMalformedQuantization.insert(
            contentsOf: malformedQuantization, at: Int(state.offset))
        XCTAssertTrue(
            validate(secondMalformedQuantization).findings.contains {
                $0.refusal?.code == .unknownQuantizationScheme
                    && $0.refusal?.site?.offset == state.offset
            })

        let birthFile = corpusDirectory().appendingPathComponent(provenanceVariant)
        let birthOriginal = try readFixture(birthFile)
        let birthWalk = try walk(birthOriginal)
        let birthSource = ToolReader(InMemoryReader(birthOriginal))
        let birthDispatch = try XCTUnwrap(try headerDispatch(birthSource, birthWalk))
        let birthHeader = try XCTUnwrap(birthWalk.firstIntact(Opcode.header))
        let birthState = try XCTUnwrap(birthWalk.firstIntact(Opcode.chunk))
        var lateBirthHeader = Array(
            birthOriginal[
                Int(birthHeader.offset)..<Int(birthHeader.offset + birthHeader.total)])
        let birthModel = Int(birthDispatch.temporalModelOffset - birthHeader.offset)
        lateBirthHeader.replaceSubrange(
            birthModel..<(birthModel + 14), with: "unknown-model!".utf8)
        var gaussianBirthWithLateHeader = birthOriginal
        gaussianBirthWithLateHeader.insert(contentsOf: lateBirthHeader, at: Int(birthState.offset))
        XCTAssertTrue(
            validate(gaussianBirthWithLateHeader).findings.contains {
                $0.refusal?.code == .unknownTemporalModel
                    && $0.refusal?.site?.offset == birthState.offset
            })
    }

    func testKeyframeDeltaValidationComposesBinsBeforeAccepting() throws {
        try requireCorpus()
        let fixture = corpusDirectory().appendingPathComponent(
            "keyframe/KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics.4dgs")
        let original = try readFixture(fixture)
        let firstState = try XCTUnwrap(try walk(original).firstIntact(Opcode.chunk))
        let front = Array(original[..<Int(firstState.offset)])

        func stream(_ attribute: UInt8, _ values: [Int32], channels: UInt8) -> [UInt8] {
            let encoded = values.map { value -> UInt32 in
                let wide = Int64(value)
                return UInt32(wide >= 0 ? wide * 2 : -wide * 2 - 1)
            }
            let largest = encoded.max() ?? 0
            let width: UInt8 = largest <= UInt8.max ? 1 : largest <= UInt16.max ? 2 : 4
            var planes = [UInt8](repeating: 0, count: encoded.count * Int(width))
            for plane in 0..<Int(width) {
                for (i, value) in encoded.enumerated() {
                    planes[plane * encoded.count + i] =
                        UInt8(truncatingIfNeeded: value >> UInt32(8 * plane))
                }
            }
            let payload = deflated(planes)
            return [attribute, width, 0, 0, channels]
                + littleU32(UInt32(values.count / Int(channels)))
                + littleU64(UInt64(payload.count)) + payload
        }

        let channelWidths: [(UInt8, UInt8)] = [
            (0, 3), (1, 3), (2, 1), (3, 3), (4, 3), (5, 1), (6, 3), (7, 1),
            (8, 1), (9, 1), (10, 1), (13, 1),
        ]
        var keyframeStreams: [UInt8] = []
        for (attribute, channels) in channelWidths {
            let values =
                attribute == 0
                ? [Int32.max, 0, 0]
                : [Int32](repeating: 0, count: Int(channels))
            keyframeStreams += stream(attribute, values, channels: channels)
        }
        var keyframeBody = littleU64(0) + littleU64(0.5.bitPattern)
        keyframeBody += littleU32(0) + littleU32(1) + littleU32(0)
        keyframeBody += littleU64(UInt64(keyframeStreams.count))
        keyframeBody += littleU64(UInt64(keyframeStreams.count)) + keyframeStreams
        let keyframe = [Opcode.chunk] + littleU64(UInt64(keyframeBody.count)) + keyframeBody

        let update = stream(13, [0], channels: 1) + stream(0, [1, 0, 0], channels: 3)
        let records = littleU64(UInt64(update.count)) + update + littleU64(0) + littleU64(0)
        let keyframeOffset = UInt64(front.count)
        var deltaBody = littleU64(0.5.bitPattern) + littleU64(1.0.bitPattern) + littleU32(0)
        deltaBody += [1] + littleU64(keyframeOffset) + littleU64(keyframeOffset) + littleU16(1)
        deltaBody += littleU32(1) + littleU32(0) + littleU32(0) + littleU32(0)
        deltaBody += littleU64(UInt64(records.count)) + littleU64(UInt64(records.count)) + records
        let delta = [Opcode.deltaChunk] + littleU64(UInt64(deltaBody.count)) + deltaBody

        let findings = validate(front + keyframe + delta).findings
        XCTAssertTrue(
            findings.contains {
                $0.message.contains("composing attribute 0 for gaussian_id 0")
                    && $0.message.contains("signed 32-bit range")
            }, findings.map(\.message).joined(separator: "\n"))

        func keyframeRecord(_ streams: [UInt8], t1: Double = 0.5) -> [UInt8] {
            var body = littleU64(0) + littleU64(t1.bitPattern)
            body += littleU32(0) + littleU32(1) + littleU32(0)
            body += littleU64(UInt64(streams.count))
            body += littleU64(UInt64(streams.count)) + streams
            return [Opcode.chunk] + littleU64(UInt64(body.count)) + body
        }

        func deltaRecord(
            t0: Double, t1: Double, reference: UInt64, keyframe: UInt64, depth: UInt16,
            updates: [UInt8] = [], births: [UInt8] = [], deaths: [UInt8] = [],
            updateCount: UInt32 = 0, birthCount: UInt32 = 0, deathCount: UInt32 = 0
        ) -> [UInt8] {
            let groups =
                littleU64(UInt64(updates.count)) + updates
                + littleU64(UInt64(births.count)) + births
                + littleU64(UInt64(deaths.count)) + deaths
            var body = littleU64(t0.bitPattern) + littleU64(t1.bitPattern) + littleU32(0)
            body += [1] + littleU64(reference) + littleU64(keyframe) + littleU16(depth)
            body += littleU32(updateCount) + littleU32(birthCount) + littleU32(deathCount)
            body += littleU32(0) + littleU64(UInt64(groups.count))
            body += littleU64(UInt64(groups.count)) + groups
            return [Opcode.deltaChunk] + littleU64(UInt64(body.count)) + body
        }

        // A duplicate birth followed by an update used to reach
        // Dictionary(uniqueKeysWithValues:) before the identity pass and trap the process.
        let duplicateKeyframe = keyframeRecord(keyframeStreams)
        let duplicateDeltaOffset = UInt64(front.count + duplicateKeyframe.count)
        let duplicateBirth = deltaRecord(
            t0: 0.5, t1: 0.75, reference: keyframeOffset, keyframe: keyframeOffset, depth: 1,
            births: keyframeStreams, birthCount: 1)
        let laterUpdate = stream(13, [0], channels: 1) + stream(1, [0, 0, 0], channels: 3)
        let updateAfterDuplicate = deltaRecord(
            t0: 0.75, t1: 1, reference: duplicateDeltaOffset, keyframe: keyframeOffset,
            depth: 2, updates: laterUpdate, updateCount: 1)
        let duplicateFindings = validate(
            front + duplicateKeyframe + duplicateBirth + updateAfterDuplicate
        ).findings
        XCTAssertTrue(
            duplicateFindings.contains {
                $0.message.contains("creates gaussian_id 0, which is already live")
            }, duplicateFindings.map(\.message).joined(separator: "\n"))

        // object_id is an absolute restatement. Repeating Int32.max is legal; adding it to
        // the prior value would overflow and falsely reject the file.
        let objectStreams = keyframeStreams + stream(14, [Int32.max], channels: 1)
        let objectKeyframe = keyframeRecord(objectStreams)
        let objectUpdate =
            stream(13, [0], channels: 1)
            + stream(14, [Int32.max], channels: 1)
        let objectDelta = deltaRecord(
            t0: 0.5, t1: 1, reference: keyframeOffset, keyframe: keyframeOffset, depth: 1,
            updates: objectUpdate, updateCount: 1)
        let objectFindings = validate(front + objectKeyframe + objectDelta).findings
        XCTAssertFalse(
            objectFindings.contains {
                $0.message.contains("composing attribute 14")
                    && $0.message.contains("signed 32-bit range")
            }, objectFindings.map(\.message).joined(separator: "\n"))

        // gaussian_id is u32 even though its Attribute Stream code is held in Int32. -1 is
        // the wire representation of UInt32.max and must survive both ordered and set decoders.
        var highIDStreams: [UInt8] = []
        for (attribute, channels) in channelWidths {
            let values =
                attribute == 13
                ? [Int32(-1)] : [Int32](repeating: 0, count: Int(channels))
            highIDStreams += stream(attribute, values, channels: channels)
        }
        let highIDKeyframe = keyframeRecord(highIDStreams)
        let highIDUpdate =
            stream(13, [-1], channels: 1)
            + stream(1, [0, 0, 0], channels: 3)
        let highIDDelta = deltaRecord(
            t0: 0.5, t1: 1, reference: keyframeOffset, keyframe: keyframeOffset, depth: 1,
            updates: highIDUpdate, updateCount: 1)
        let highIDFindings = validate(front + highIDKeyframe + highIDDelta).findings
        XCTAssertFalse(
            highIDFindings.contains {
                $0.message.contains("gaussian_id -1") && $0.message.contains("expected a u32")
            }, highIDFindings.map(\.message).joined(separator: "\n"))
    }

    func testAnEmptyNonzeroSummaryRangeIsInvalid() throws {
        try requireCorpus()
        var bytes = try readFixture(corpusDirectory().appendingPathComponent(provenanceVariant))
        let footer = try XCTUnwrap(try walk(bytes).firstIntact(Opcode.footer))
        writeU64(footer.offset, into: &bytes, at: footer.offset + recordHeaderSize)
        XCTAssertTrue(
            validate(bytes).findings.contains {
                $0.message
                    == "the Footer's nonzero summary_start \(footer.offset) names no ChunkIndex record"
            })
    }

    func testEverySummaryRecordMustBeInsideTheDeclaredRun() throws {
        try requireCorpus()
        let variant =
            "TenWindows-UseChunkIndex-UseChunks-UseCrc-UseStatistics-UseSummaryOffset.4dgs"
        var bytes = try readFixture(corpusDirectory().appendingPathComponent(variant))
        let walked = try walk(bytes)
        let statistics = try XCTUnwrap(walked.firstIntact(Opcode.statistics))
        let footer = try XCTUnwrap(walked.firstIntact(Opcode.footer))
        writeU64(
            statistics.offset + statistics.total,
            into: &bytes,
            at: footer.offset + recordHeaderSize)
        writeU32(0, into: &bytes, at: footer.offset + recordHeaderSize + 16)
        let findings = validate(bytes).findings
        XCTAssertTrue(
            findings.contains {
                $0.message
                    == "Statistics at byte \(statistics.offset) lies outside the Footer-declared summary"
            }, findings.map(\.message).joined(separator: "\n"))
    }

    func testAttributeStreamCannotFrameATopLevelRecord() throws {
        try requireCorpus()
        var bytes = try readFixture(corpusDirectory().appendingPathComponent(provenanceVariant))
        let footer = try XCTUnwrap(try walk(bytes).firstIntact(Opcode.footer))
        bytes.insert(contentsOf: [Opcode.attributeStream] + littleU64(0), at: Int(footer.offset))
        XCTAssertTrue(
            validate(bytes).findings.contains {
                $0.message
                    == "AttributeStream at byte \(footer.offset) is a bare Chunk structure, not a top-level record"
            })
    }

    func testKeyframeDeltaChainResolutionIsLinearAfterSorting() {
        let count = 20_000
        let firstOffset: UInt64 = 1_000
        let stride: UInt64 = 100
        var entries: [IndexEntry] = []
        entries.reserveCapacity(count)
        for i in 0..<count {
            let offset = firstOffset + UInt64(i) * stride
            entries.append(
                IndexEntry(
                    t0: Double(i), t1: Double(i + 1), offset: offset, length: stride,
                    gaussianCount: 1, bands: [], extended: true, kind: i == 0 ? 0 : 1,
                    deltaMode: i == 0 ? 0 : 1,
                    referenceOffset: i == 0 ? 0 : offset - stride,
                    keyframeOffset: firstOffset, depth: UInt16(i), liveCount: 1))
        }
        var report = Report()

        validateKeyframeDeltaIndex(
            entries, fields: [:], durationSec: Double(count), report: &report)

        XCTAssertTrue(report.ok, "\(report.findings.map(\.message))")
    }

    func testKeyframeDeltaRejectsAForwardReferenceAndIndexRecordDisagreement() throws {
        try requireCorpus()
        let file = corpusDirectory().appendingPathComponent(
            "keyframe/KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics.4dgs")
        var bytes = try readFixture(file)
        let walked = try walk(bytes)
        let frames = walked.records.filter { $0.opcode == Opcode.chunkIndex }
        let entries = chunkIndexEntries(bytes, walked)
        let delta = try XCTUnwrap(entries.firstIndex { $0.kind == 1 })
        let frame = frames[delta]
        let bandCount = UInt64(
            try XCTUnwrap(readU32(bytes, at: frame.offset + recordHeaderSize + 36)))
        let extensionOffset = frame.offset + recordHeaderSize + 40 + bandCount * 17
        writeU64(entries[delta].offset, into: &bytes, at: extensionOffset + 2)

        let report = validate(bytes)
        XCTAssertFalse(report.ok)
        XCTAssertTrue(
            report.findings.contains {
                $0.message
                    == "the chunk at \(entries[delta].offset) references \(entries[delta].offset), "
                    + "which is not behind it; references point backwards only"
            }, "\(report.findings.map(\.message))")
        XCTAssertTrue(
            report.findings.contains {
                $0.message.contains("chunk index entry \(delta) has reference_offset")
                    && $0.message.contains("but the DeltaChunk at byte")
            }, "\(report.findings.map(\.message))")
    }

    func testKeyframeDeltaDispatchReadsPastALongHeaderPrefix() throws {
        let longLibrary = [UInt8](repeating: 0x61, count: 5000)
        var content = littleU32(0)  // profile
        content += littleU32(UInt32(longLibrary.count)) + longLibrary
        content += [UInt8](repeating: 0, count: 24)  // duration, gaussian count, cutoff
        let model = Array("keyframe-delta".utf8)
        content += littleU32(UInt32(model.count)) + model
        content += [UInt8](repeating: 0, count: 50)  // aabb, sh_degree, flags
        let bytes = magic + [Opcode.header] + littleU64(UInt64(content.count)) + content + magic
        let recording = RecordingReader(bytes)
        let source = ToolReader(recording)
        let walked = try walk(source, retaining: { $0.opcode == Opcode.header })

        XCTAssertTrue(try isKeyframeDelta(source, walked))
        XCTAssertLessThanOrEqual(recording.largestRead, 24)
    }

    func testFooterMustBeTheFinalRecordForKeyframeDelta() throws {
        try requireCorpus()
        let file = try XCTUnwrap(
            variants(corpusDirectory().appendingPathComponent("keyframe")).first)
        var bytes = try readFixture(file)
        bytes.insert(
            contentsOf: [Opcode.privateStart] + littleU64(0), at: bytes.count - magic.count)

        let report = validate(bytes)
        XCTAssertFalse(report.ok)
        XCTAssertTrue(
            report.findings.contains {
                $0.message == "last record is Private(0x80); the Footer must be the final record"
            }, "\(report.findings.map(\.message))")
    }

    func testValidationDoesNotRequestTheWholeFile() throws {
        try requireCorpus()
        let files = [
            corpusDirectory().appendingPathComponent(provenanceVariant),
            corpusDirectory().appendingPathComponent("TenWindows-UseCrc.4dgs"),
            try XCTUnwrap(variants(corpusDirectory().appendingPathComponent("keyframe")).first),
        ]
        for file in files {
            let bytes = try readFixture(file)
            XCTAssertGreaterThan(bytes.count, 4096)
            let recording = RecordingReader(bytes)
            let report = validate(ToolReader(recording))
            XCTAssertFalse(
                report.findings.contains { $0.severity == .error },
                "\(file.lastPathComponent): \(report.findings.map(\.message))")
            XCTAssertLessThan(recording.largestRead, bytes.count, file.lastPathComponent)
        }
    }

    func testHostilePhysicalAndSummaryShapesAreRejected() throws {
        try requireCorpus()
        let indexedURL = corpusDirectory().appendingPathComponent(
            "MixedLifetimes-SHDegree3-UseChunkIndex-UseCrc.4dgs")
        let original = try readFixture(indexedURL)
        let walked = try walk(original)
        let footer = try XCTUnwrap(walked.firstIntact(Opcode.footer))
        let indexFrames = walked.records.filter { $0.opcode == Opcode.chunkIndex }

        func says(_ bytes: [UInt8], _ fragment: String) {
            XCTAssertTrue(
                validate(bytes).findings.contains { $0.message.contains(fragment) }, fragment)
        }

        var noIndex = original
        for frame in indexFrames { noIndex[Int(frame.offset)] = Opcode.privateStart }
        writeU64(0, into: &noIndex, at: footer.offset + recordHeaderSize)
        writeU32(0, into: &noIndex, at: footer.offset + recordHeaderSize + 16)
        let band = try XCTUnwrap(walked.firstIntact(Opcode.shBandStream))
        noIndex[Int(band.offset + recordHeaderSize + 4)] = 9
        XCTAssertTrue(
            validate(noIndex).findings.compactMap(\.refusal).contains {
                $0.code == .unknownStreamCodec
            })

        var embedded = original
        let entry = try XCTUnwrap(chunkIndexEntries(original, walked).first)
        let inside = entry.offset + recordHeaderSize + 44
        embedded[Int(inside)] = Opcode.chunk
        writeU64(0, into: &embedded, at: inside + 1)
        writeU64(inside, into: &embedded, at: indexFrames[0].offset + recordHeaderSize + 16)
        writeU64(9, into: &embedded, at: indexFrames[0].offset + recordHeaderSize + 24)
        says(embedded, "not the start of an intact physical Chunk or DeltaChunk record")

        var tooManyBands = original
        writeU32(
            4, into: &tooManyBands,
            at: indexFrames[0].offset + recordHeaderSize + 36)
        says(tooManyBands, "band_count")

        let keyframeURL = corpusDirectory().appendingPathComponent(
            "keyframe/KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics.4dgs")
        let keyframe = try readFixture(keyframeURL)
        let keyframeWalk = try walk(keyframe)
        let statistics = try XCTUnwrap(keyframeWalk.firstIntact(Opcode.statistics))
        let keyframeFooter = try XCTUnwrap(keyframeWalk.firstIntact(Opcode.footer))

        var wrongSummaryStart = keyframe
        writeU64(
            statistics.offset, into: &wrongSummaryStart,
            at: keyframeFooter.offset + recordHeaderSize)
        writeU32(
            0, into: &wrongSummaryStart,
            at: keyframeFooter.offset + recordHeaderSize + 16)
        says(wrongSummaryStart, "expected the first ChunkIndex")

        var lateAudio = keyframe
        lateAudio[Int(statistics.offset)] = Opcode.audioSource
        says(lateAudio, "appears after the first Chunk or DeltaChunk")

        var shortFooter = keyframe
        writeU64(19, into: &shortFooter, at: keyframeFooter.offset + 1)
        says(shortFooter, "malformed Footer.fixed fields")
    }

    func testIndexedBandsBelongToTheirPhysicalState() throws {
        try requireCorpus()
        var bytes = try readFixture(
            corpusDirectory().appendingPathComponent(
                "MixedLifetimes-SHDegree3-UseChunkIndex-UseCrc.4dgs"))
        let walked = try walk(bytes)
        let frames = walked.records.filter { $0.opcode == Opcode.chunkIndex }
        let entries = chunkIndexEntries(bytes, walked)
        let owners = entries.indices.filter { !entries[$0].bands.isEmpty }
        XCTAssertGreaterThanOrEqual(owners.count, 2)
        let first = owners[0]
        let second = owners[1]
        let firstBand = entries[first].bands[0]
        let secondBand = entries[second].bands[0]
        writeU64(
            secondBand.offset, into: &bytes,
            at: frames[first].offset + recordHeaderSize + 41)
        writeU64(
            secondBand.length, into: &bytes,
            at: frames[first].offset + recordHeaderSize + 49)
        writeU64(
            firstBand.offset, into: &bytes,
            at: frames[second].offset + recordHeaderSize + 41)
        writeU64(
            firstBand.length, into: &bytes,
            at: frames[second].offset + recordHeaderSize + 49)

        let report = validate(bytes)
        XCTAssertTrue(
            report.findings.contains { $0.message.contains("stream physically follows") },
            "\(report.findings.map(\.message))")
    }

    func testKeyframeDeltaPhysicalTimelineIsCheckedWithoutAnIndex() throws {
        try requireCorpus()
        let file = corpusDirectory().appendingPathComponent(
            "keyframe/KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics.4dgs")
        var bytes = try readFixture(file)
        let walked = try walk(bytes)
        let states = walked.records.filter {
            $0.opcode == Opcode.chunk || $0.opcode == Opcode.deltaChunk
        }
        XCTAssertGreaterThanOrEqual(states.count, 2)
        let firstEnd = try XCTUnwrap(
            readU64(bytes, at: states[0].offset + recordHeaderSize + 8))
        writeU64(
            (Double(bitPattern: firstEnd) + 0.25).bitPattern, into: &bytes,
            at: states[1].offset + recordHeaderSize)
        for frame in walked.records where frame.opcode == Opcode.chunkIndex {
            bytes[Int(frame.offset)] = Opcode.privateStart
        }
        let footer = try XCTUnwrap(walked.firstIntact(Opcode.footer))
        writeU64(0, into: &bytes, at: footer.offset + recordHeaderSize)
        writeU32(0, into: &bytes, at: footer.offset + recordHeaderSize + 16)

        let report = validate(bytes)
        XCTAssertTrue(
            report.findings.contains { $0.message.hasPrefix("physical state chunks leave a gap") },
            "\(report.findings.map(\.message))")
    }

    func testFooterAndChunkIndexPlacementArePhysicalRules() throws {
        try requireCorpus()
        let original = try readFixture(corpusDirectory().appendingPathComponent(provenanceVariant))
        let walked = try walk(original)
        let footer = try XCTUnwrap(walked.firstIntact(Opcode.footer))

        var duplicateFooter = original
        duplicateFooter.insert(
            contentsOf: [Opcode.footer] + littleU64(20) + [UInt8](repeating: 0, count: 20),
            at: Int(footer.offset))
        XCTAssertTrue(
            validate(duplicateFooter).findings.contains {
                $0.message
                    == "Footer at byte \(footer.offset) is not final; exactly one Footer must be "
                    + "the final record"
            })

        var orphanIndex = original
        writeU64(0, into: &orphanIndex, at: footer.offset + recordHeaderSize)
        writeU32(0, into: &orphanIndex, at: footer.offset + recordHeaderSize + 16)
        XCTAssertTrue(
            validate(orphanIndex).findings.contains {
                $0.message.contains("lies outside the Footer-declared summary")
            })

        var manyFooters = original
        let extraFooter = [Opcode.footer] + littleU64(20) + [UInt8](repeating: 0, count: 20)
        for _ in 0..<20 {
            manyFooters.insert(contentsOf: extraFooter, at: Int(footer.offset))
        }
        let repeated = validate(manyFooters).findings.filter {
            $0.message.contains("Footer") && $0.message.contains("not final")
        }
        XCTAssertEqual(repeated.count, 1, "\(repeated.map(\.message))")
        XCTAssertTrue(repeated[0].message.contains("20 Footer records"))
    }

    func testGaussianBirthHeaderAndIndexMetadataMatchPhysicalState() throws {
        try requireCorpus()
        let original = try readFixture(corpusDirectory().appendingPathComponent(provenanceVariant))
        let walked = try walk(original)
        let source = ToolReader(InMemoryReader(original))
        let dispatch = try XCTUnwrap(try headerDispatch(source, walked))
        let header = try XCTUnwrap(walked.firstIntact(Opcode.header))
        let content = header.offset + recordHeaderSize
        var relative: UInt64 = 0
        for _ in 0..<2 {
            let length = UInt64(try XCTUnwrap(readU32(original, at: content + relative)))
            relative += 4 + length
        }

        var wrongCount = original
        writeU64(
            dispatch.gaussianCount + 1, into: &wrongCount,
            at: content + relative + 8)
        XCTAssertTrue(
            validate(wrongCount).findings.contains { $0.message.hasPrefix("Header gaussian_count") })

        var wrongDegree = original
        wrongDegree[Int(dispatch.temporalModelOffset + 14 + 48)] = 3
        XCTAssertTrue(
            validate(wrongDegree).findings.contains {
                $0.message.contains("physical SH Band Streams")
            })

        let index = try XCTUnwrap(walked.firstIntact(Opcode.chunkIndex))
        var extended = original
        extended.insert(contentsOf: [UInt8](repeating: 0, count: 28), at: Int(index.offset + index.total))
        writeU64(index.length + 28, into: &extended, at: index.offset + 1)
        let shiftedFooter = try XCTUnwrap(try walk(extended).firstIntact(Opcode.footer)).offset
        writeU32(0, into: &extended, at: shiftedFooter + recordHeaderSize + 16)
        XCTAssertTrue(
            validate(extended).findings.contains {
                $0.message.contains("keyframe-delta fields in a gaussian-birth file")
            })

        let entry = try XCTUnwrap(chunkIndexEntries(original, walked).first)
        var wrongInterval = original
        writeU64(
            (entry.t0 + 0.125).bitPattern, into: &wrongInterval,
            at: index.offset + recordHeaderSize)
        let footer = try XCTUnwrap(walked.firstIntact(Opcode.footer))
        writeU32(0, into: &wrongInterval, at: footer.offset + recordHeaderSize + 16)
        XCTAssertTrue(
            validate(wrongInterval).findings.contains {
                $0.message.contains("has t0") && $0.message.contains("the Chunk at byte")
            })

        let chunk = try XCTUnwrap(walked.firstIntact(Opcode.chunk))
        let t0 = try XCTUnwrap(readF64(original, at: chunk.offset + recordHeaderSize))
        let reversedEnd = t0 - 1
        var reversedInterval = original
        writeU64(
            reversedEnd.bitPattern, into: &reversedInterval,
            at: chunk.offset + recordHeaderSize + 8)
        writeU64(
            reversedEnd.bitPattern, into: &reversedInterval,
            at: index.offset + recordHeaderSize + 8)
        writeU32(0, into: &reversedInterval, at: footer.offset + recordHeaderSize + 16)
        XCTAssertTrue(
            validate(reversedInterval).findings.contains {
                $0.message.contains("physical Chunk at byte \(chunk.offset)")
                    && $0.message.contains("expected finite values with t0 <= t1")
            })

        var wrongIndexCount = original
        writeU32(
            entry.gaussianCount + 1, into: &wrongIndexCount,
            at: index.offset + recordHeaderSize + 32)
        writeU32(0, into: &wrongIndexCount, at: footer.offset + recordHeaderSize + 16)
        XCTAssertTrue(
            validate(wrongIndexCount).findings.contains {
                $0.message.contains("declares gaussian_count")
                    && $0.message.contains("physical Chunk")
            })

        var duplicateIndex = original
        let indexBytes = original[Int(index.offset)..<Int(index.offset + index.total)]
        duplicateIndex.insert(contentsOf: indexBytes, at: Int(footer.offset))
        let duplicateFooterOffset = footer.offset + index.total
        writeU32(0, into: &duplicateIndex, at: duplicateFooterOffset + recordHeaderSize + 16)
        XCTAssertTrue(
            validate(duplicateIndex).findings.contains {
                $0.message.contains("each state record must have one index entry")
            })
    }

    func testPhysicalStateShapeAndOrderingDoNotDependOnTheIndex() throws {
        try requireCorpus()
        let file = corpusDirectory().appendingPathComponent(
            "keyframe/KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics.4dgs")
        let original = try readFixture(file)
        let walked = try walk(original)
        let dispatch = try XCTUnwrap(
            try headerDispatch(ToolReader(InMemoryReader(original)), walked))
        let firstState = try XCTUnwrap(
            walked.records.first { $0.opcode == Opcode.chunk || $0.opcode == Opcode.deltaChunk })
        let quantization = try XCTUnwrap(walked.firstIntact(Opcode.quantization))

        var missingKeyframeBands = original
        missingKeyframeBands[Int(dispatch.temporalModelOffset + 14 + 48)] = 1
        XCTAssertTrue(
            validate(missingKeyframeBands).findings.contains {
                $0.message.contains("physical SH Band Streams")
                    && $0.message.contains("missing bands [1]")
            })

        let schemeLength = UInt64(
            try XCTUnwrap(
                readU32(original, at: quantization.offset + recordHeaderSize)))
        var nonFiniteGrid = original
        writeU64(
            Double.nan.bitPattern, into: &nonFiniteGrid,
            at: quantization.offset + recordHeaderSize + 4 + schemeLength)
        XCTAssertTrue(
            validate(nonFiniteGrid).findings.contains {
                $0.message.contains("Quantization")
                    && $0.message.contains("finite grid parameter")
            })

        var malformedSecondWindow = original
        malformedSecondWindow.insert(
            contentsOf: [Opcode.windowTable] + littleU64(0), at: Int(firstState.offset))
        let malformedWindowFindings = validate(malformedSecondWindow).findings
        XCTAssertTrue(
            malformedWindowFindings.contains {
                $0.message.contains("physical WindowTable record at byte \(firstState.offset)")
            }, malformedWindowFindings.map(\.message).joined(separator: "\n"))

        var stateBeforeQuantization = original
        let stateBytes = original[
            Int(firstState.offset)..<Int(firstState.offset + firstState.total)]
        stateBeforeQuantization.insert(contentsOf: stateBytes, at: Int(quantization.offset))
        XCTAssertTrue(
            validate(stateBeforeQuantization).findings.contains {
                $0.message.contains("appears before Quantization")
            })

        var malformedAuxiliary = original
        malformedAuxiliary.insert(
            contentsOf: [Opcode.coordinateFrame] + littleU64(0), at: Int(firstState.offset))
        let auxiliaryFindings = validate(malformedAuxiliary).findings
        XCTAssertTrue(
            auxiliaryFindings.contains {
                $0.message.contains("physical CoordinateFrame record at byte \(firstState.offset)")
            },
            auxiliaryFindings.map { "\($0.message) [\($0.refusal.map(String.init(describing:)) ?? "-")]" }
                .joined(separator: "\n"))
    }

    func testCoordinateFrameUnitDeclarationsMustAgree() throws {
        try requireCorpus()
        var bytes = try readFixture(corpusDirectory().appendingPathComponent(provenanceVariant))
        let frame = try XCTUnwrap(try walk(bytes).firstIntact(Opcode.coordinateFrame))
        let content = frame.offset + recordHeaderSize
        let nameLength = UInt64(try XCTUnwrap(readU32(bytes, at: content)))
        let fixed = content + 4 + nameLength
        bytes[Int(fixed + 3)] = 1  // metre
        writeU64(0.01.bitPattern, into: &bytes, at: fixed + 4)

        let findings = validate(bytes).findings
        XCTAssertTrue(
            findings.contains {
                $0.message.contains("length_unit 1 (1.0 m per unit)")
                    && $0.message.contains("metres_per_unit 0.01")
            }, findings.map(\.message).joined(separator: "\n"))
    }

    func testAttachmentValidationSkipsThePayload() throws {
        let payloadCount = 8 * 1024 * 1024
        var body = littleU32(0) + littleU32(0) + littleU64(UInt64(payloadCount))
        body += [UInt8](repeating: 0xA5, count: payloadCount)
        let bytes = [Opcode.attachment] + littleU64(UInt64(body.count)) + body
        let frame = Frame(opcode: Opcode.attachment, offset: 0, length: UInt64(body.count))
        let recording = RecordingReader(bytes)

        try validateAttachmentShape(ToolReader(recording), frame)
        XCTAssertLessThan(recording.largestRead, payloadCount)
        let payload = Int(recordHeaderSize) + 16
        let payloadRange = payload..<(payload + payloadCount)
        XCTAssertFalse(
            recording.ranges.contains {
                $0.lowerBound < payloadRange.upperBound && $0.upperBound > payloadRange.lowerBound
            })

        let shortBody = littleU32(0) + littleU32(0) + littleU64(1)
        let malformed = [Opcode.attachment] + littleU64(UInt64(shortBody.count)) + shortBody
        let malformedFrame = Frame(
            opcode: Opcode.attachment, offset: 0, length: UInt64(shortBody.count))
        XCTAssertThrowsError(
            try validateAttachmentShape(ToolReader(InMemoryReader(malformed)), malformedFrame)
        ) { error in
            XCTAssertTrue(sentence(asFourDGS(error)).contains("declares 1 bytes; 0 remain"))
        }
    }

    func testAuxiliaryValidationHasAnAggregateByteCeiling() {
        XCTAssertEqual(
            nextAuxiliaryValidationBytes(0, adding: maximumAuxiliaryValidationBytes),
            maximumAuxiliaryValidationBytes)
        XCTAssertNil(
            nextAuxiliaryValidationBytes(0, adding: maximumAuxiliaryValidationBytes + 1))
        XCTAssertNil(nextAuxiliaryValidationBytes(UInt64.max, adding: 1))
    }

    func testConstantValidationColumnsStayCompressed() throws {
        let channels: UInt8 = 255
        let rows: UInt32 = 500_000
        let payload = deflated([UInt8](repeating: 0, count: Int(channels)))
        let stream =
            [UInt8(42), 1, 2, 0, channels] + littleU32(rows)
            + littleU64(UInt64(payload.count)) + payload
        let recording = RecordingReader(stream)
        let source = ToolReader(recording)
        let group = DeltaGroup(
            name: "update", count: rows, source: source, offset: 0,
            length: UInt64(stream.count))
        let frame = Frame(opcode: Opcode.deltaChunk, offset: 0, length: UInt64(stream.count))

        var column = try XCTUnwrap(validationColumn(frame, group, attribute: 42))
        XCTAssertEqual(column.rowCount, Int(rows))
        XCTAssertEqual(column.storedValueCount, Int(channels))
        XCTAssertEqual(column.rowValues(at: Int(rows) - 1), [Int32](repeating: 0, count: 255))
        column.setRow([Int32](repeating: 1, count: 255), at: Int(rows) - 1)
        XCTAssertEqual(column.storedValueCount, Int(channels) * 2)
        XCTAssertEqual(column.rowValues(at: 0), [Int32](repeating: 0, count: 255))
        XCTAssertEqual(column.rowValues(at: Int(rows) - 1), [Int32](repeating: 1, count: 255))
    }

    func testHeaderDegreeAndQuantizationDepthsAreValidatedDirectly() throws {
        try requireCorpus()
        let file = corpusDirectory().appendingPathComponent(
            "MixedLifetimes-SHDegree3-UseChunkIndex-UseCrc.4dgs")
        let original = try readFixture(file)
        let walked = try walk(original)
        let dispatch = try XCTUnwrap(
            try headerDispatch(ToolReader(InMemoryReader(original)), walked))

        var impossibleDegree = original
        impossibleDegree[Int(dispatch.temporalModelOffset + 14 + 48)] = 4
        XCTAssertTrue(
            validate(impossibleDegree).findings.contains {
                $0.message.contains("Header") && $0.message.contains("sh_degree")
                    && $0.message.contains("0 through 3")
            })

        let quantization = try XCTUnwrap(walked.firstIntact(Opcode.quantization))
        let content = quantization.offset + recordHeaderSize
        let schemeLength = UInt64(try XCTUnwrap(readU32(original, at: content)))
        let suffix = content + 4 + schemeLength + 11 * 8
        let boundsLength = UInt64(try XCTUnwrap(readU32(original, at: suffix + 1)))
        let depthsAt = suffix + 5 + boundsLength
        XCTAssertEqual(depthsAt, quantization.offset + quantization.total)
        var wrongDepthCount = original
        wrongDepthCount.insert(contentsOf: [1, 8], at: Int(depthsAt))
        writeU64(
            quantization.length + 2, into: &wrongDepthCount, at: quantization.offset + 1)
        XCTAssertTrue(
            validate(wrongDepthCount).findings.contains {
                $0.message.contains("sh_depth_count")
                    && $0.message.contains("Header sh_degree 3 requires one per band")
            })
    }

    func testGaussianBirthAuxiliaryRecordsAreParsedToo() throws {
        try requireCorpus()
        let file = corpusDirectory().appendingPathComponent(provenanceVariant)
        let original = try readFixture(file)
        let walked = try walk(original)
        let state = try XCTUnwrap(walked.firstIntact(Opcode.chunk))
        var bytes = original
        bytes.insert(
            contentsOf: [Opcode.coordinateFrame] + littleU64(0), at: Int(state.offset))
        let findings = validate(bytes).findings
        XCTAssertTrue(
            findings.contains {
                $0.message.contains("physical CoordinateFrame record at byte \(state.offset)")
            }, findings.map(\.message).joined(separator: "\n"))

        // The indexed core stops its front-matter scan at the first state, but physical
        // validation still has to parse a replacement WindowTable after the last Chunk.
        let footer = try XCTUnwrap(walked.firstIntact(Opcode.footer))
        var lateWindow = original
        lateWindow.insert(
            contentsOf: [Opcode.windowTable] + littleU64(0), at: Int(footer.offset))
        let lateFindings = validate(lateWindow).findings
        XCTAssertTrue(
            lateFindings.contains {
                $0.message.contains("physical WindowTable record at byte \(footer.offset)")
            }, lateFindings.map(\.message).joined(separator: "\n"))
    }

    func testEveryPhysicalBandMustAppearInItsOwningIndexEntry() throws {
        try requireCorpus()
        let file = corpusDirectory().appendingPathComponent(
            "MixedLifetimes-SHDegree3-UseChunkIndex-UseCrc.4dgs")
        var bytes = try readFixture(file)
        let walked = try walk(bytes)
        let footer = try XCTUnwrap(walked.firstIntact(Opcode.footer))
        for frame in walked.records where frame.opcode == Opcode.chunkIndex {
            writeU32(0, into: &bytes, at: frame.offset + recordHeaderSize + 36)
        }
        writeU32(0, into: &bytes, at: footer.offset + recordHeaderSize + 16)

        XCTAssertTrue(
            validate(bytes).findings.contains {
                $0.message.contains("physical SH Band Stream")
                    && $0.message.contains("absent from the Chunk Index entry")
            })
    }

    func testKeyframeIdentityAndAudioPairingAreCheckedStructurally() throws {
        try requireCorpus()
        let keyframeFile = corpusDirectory().appendingPathComponent(
            "keyframe/KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics.4dgs")
        var missingIdentity = try readFixture(keyframeFile)
        let keyframeWalk = try walk(missingIdentity)
        let keyframeDispatch = try XCTUnwrap(
            try headerDispatch(ToolReader(InMemoryReader(missingIdentity)), keyframeWalk))
        let keyframeHeader = try XCTUnwrap(keyframeWalk.firstIntact(Opcode.header))
        var headerRelative: UInt64 = 0
        for _ in 0..<2 {
            let length = UInt64(
                try XCTUnwrap(
                    readU32(
                        missingIdentity,
                        at: keyframeHeader.offset + recordHeaderSize + headerRelative)))
            headerRelative += 4 + length
        }
        var wrongDistinctCount = missingIdentity
        writeU64(
            keyframeDispatch.gaussianCount + 1, into: &wrongDistinctCount,
            at: keyframeHeader.offset + recordHeaderSize + headerRelative + 8)
        XCTAssertTrue(
            validate(wrongDistinctCount).findings.contains {
                $0.message.contains("keyframe-delta sequence")
                    && $0.message.contains("distinct gaussian_id values")
            })

        var reservedHeaderFlags = missingIdentity
        reservedHeaderFlags[Int(keyframeDispatch.temporalModelOffset + 14 + 49)] |= 0x80
        XCTAssertTrue(
            validate(reservedHeaderFlags).findings.contains {
                $0.message.contains("Header flags contain reserved bits")
            })
        let keyframe = try XCTUnwrap(keyframeWalk.firstIntact(Opcode.chunk))
        var stream = keyframe.offset + recordHeaderSize + 44
        let streamEnd = keyframe.offset + keyframe.total
        var identityOffset: UInt64?
        while stream < streamEnd {
            if missingIdentity[Int(stream)] == 13 { identityOffset = stream; break }
            let payload = try XCTUnwrap(readU64(missingIdentity, at: stream + 9))
            stream += 17 + payload
        }
        missingIdentity[Int(try XCTUnwrap(identityOffset))] = 14
        XCTAssertTrue(
            validate(missingIdentity).findings.contains {
                $0.message.contains("keyframe group carries no gaussian_id stream")
            })

        var constantIdentity = try readFixture(keyframeFile)
        constantIdentity[Int(try XCTUnwrap(identityOffset)) + 2] = 2
        XCTAssertTrue(
            validate(constantIdentity).findings.contains {
                $0.message.contains("constant gaussian_id stream")
                    && $0.message.contains("duplicates an identity")
            })

        let audioFile = corpusDirectory().appendingPathComponent(
            "OneWindow-UseChunkIndex-UseCrc-WithSpatialAudio.4dgs")
        var audio = try readFixture(audioFile)
        let audioWalk = try walk(audio)
        let audioDispatch = try XCTUnwrap(
            try headerDispatch(ToolReader(InMemoryReader(audio)), audioWalk))
        var wrongAudioFlag = audio
        wrongAudioFlag[Int(audioDispatch.temporalModelOffset + 14 + 49)] &= ~UInt8(1)
        XCTAssertTrue(
            validate(wrongAudioFlag).findings.contains {
                $0.message.contains("Header has-audio flag is clear")
            })
        audio.replaceSubrange(
            Int(audioDispatch.temporalModelOffset)..<Int(audioDispatch.temporalModelOffset + 14),
            with: "keyframe-delta".utf8)
        let descriptor = try XCTUnwrap(audioWalk.firstIntact(Opcode.audioSource))
        var relative: UInt64 = 4
        for _ in 0..<3 {
            let length = UInt64(
                try XCTUnwrap(
                    readU32(audio, at: descriptor.offset + recordHeaderSize + relative)))
            relative += 4 + length
        }
        let dataLengthAt = descriptor.offset + recordHeaderSize + relative
        let dataLength = try XCTUnwrap(readU64(audio, at: dataLengthAt))
        writeU64(dataLength + 1, into: &audio, at: dataLengthAt)
        XCTAssertTrue(
            validate(audio).findings.contains {
                $0.message.contains("declares \(dataLength + 1) data bytes")
            })
    }

    func testKeyframeDeltaValidatesCompleteAudioDescriptorsAndLegacyAudioAccounting() throws {
        try requireCorpus()
        let audioFile = corpusDirectory().appendingPathComponent(
            "OneWindow-UseChunkIndex-UseCrc-WithSpatialAudio.4dgs")
        let original = try readFixture(audioFile)
        let originalWalk = try walk(original)
        let dispatch = try XCTUnwrap(
            try headerDispatch(ToolReader(InMemoryReader(original)), originalWalk))
        let descriptor = try XCTUnwrap(originalWalk.firstIntact(Opcode.audioSource))
        let payload = try XCTUnwrap(originalWalk.firstIntact(Opcode.audioData))

        var keyframeDelta = original
        keyframeDelta.replaceSubrange(
            Int(dispatch.temporalModelOffset)..<Int(dispatch.temporalModelOffset + 14),
            with: "keyframe-delta".utf8)
        var relative: UInt64 = 4
        for _ in 0..<3 {
            let length = UInt64(
                try XCTUnwrap(
                    readU32(
                        keyframeDelta,
                        at: descriptor.offset + recordHeaderSize + relative)))
            relative += 4 + length
        }
        let dataLengthAt = descriptor.offset + recordHeaderSize + relative

        var reservedFlags = keyframeDelta
        reservedFlags[Int(dataLengthAt + 32)] |= 0x80
        XCTAssertTrue(
            validate(reservedFlags).findings.contains {
                $0.message.contains("Audio Source.flags")
                    && $0.message.contains("reserved flag bits")
            })

        var legacyOnly = keyframeDelta
        legacyOnly[Int(descriptor.offset)] = Opcode.audio
        legacyOnly[Int(payload.offset)] = Opcode.privateStart
        XCTAssertFalse(
            validate(legacyOnly).findings.contains {
                $0.message.contains("Header has-audio flag")
            })

        var mixed = keyframeDelta
        let firstState = try XCTUnwrap(
            originalWalk.records.first {
                $0.opcode == Opcode.chunk || $0.opcode == Opcode.deltaChunk
            })
        mixed.insert(
            contentsOf: [Opcode.audio] + littleU64(0), at: Int(firstState.offset))
        XCTAssertTrue(
            validate(mixed).findings.contains {
                $0.message == "legacy Audio and Audio Source records must not be mixed"
            })

        var malformedLegacy = keyframeDelta
        malformedLegacy.insert(
            contentsOf: [Opcode.audio] + littleU64(4) + littleU32(100),
            at: Int(firstState.offset))
        XCTAssertTrue(
            validate(malformedLegacy).findings.contains {
                $0.message.contains("Audio at byte \(firstState.offset) does not parse")
                    && $0.message.contains("codec")
            })
    }

    func testKeyframeDeltaBirthBandsLiveCountsAndPhysicalOrdering() throws {
        try requireCorpus()
        let churnFile = corpusDirectory().appendingPathComponent(
            "keyframe/KeyframeDeltaChurn-UseChunkIndex-UseCrc-UseStatistics.4dgs")
        let churn = try readFixture(churnFile)
        let churnWalk = try walk(churn)
        let churnDispatch = try XCTUnwrap(
            try headerDispatch(ToolReader(InMemoryReader(churn)), churnWalk))

        var missingBirthBands = churn
        missingBirthBands[Int(churnDispatch.temporalModelOffset + 14 + 48)] = 1
        XCTAssertTrue(
            validate(missingBirthBands).findings.contains {
                $0.message.contains("DeltaChunk at byte") && $0.message.contains("births")
                    && $0.message.contains("missing bands [1]")
            })

        let indexFrame = try XCTUnwrap(
            churnWalk.intactRecords.first { frame in
                guard frame.opcode == Opcode.chunkIndex else { return false }
                return chunkIndexEntries(churn, churnWalk).first?.kind == 0
            })
        let entry = try XCTUnwrap(chunkIndexEntries(churn, churnWalk).first)
        let bandCount = UInt64(
            try XCTUnwrap(readU32(churn, at: indexFrame.offset + recordHeaderSize + 36)))
        let extensionOffset = indexFrame.offset + recordHeaderSize + 40 + bandCount * 17
        var wrongLiveCount = churn
        writeU64(entry.liveCount + 1, into: &wrongLiveCount, at: extensionOffset + 20)
        let footer = try XCTUnwrap(churnWalk.firstIntact(Opcode.footer))
        writeU32(0, into: &wrongLiveCount, at: footer.offset + recordHeaderSize + 16)
        XCTAssertTrue(
            validate(wrongLiveCount).findings.contains {
                $0.message.contains("live_count \(entry.liveCount + 1)")
                    && $0.message.contains("keyframe Chunk")
            })

        let keyframesFile = corpusDirectory().appendingPathComponent(
            "keyframe/KeyframeOnly-UseChunkIndex-UseCrc-UseStatistics.4dgs")
        var reordered = try readFixture(keyframesFile)
        let reorderedWalk = try walk(reordered)
        let states = reorderedWalk.intactRecords.filter { $0.opcode == Opcode.chunk }
        XCTAssertGreaterThanOrEqual(states.count, 2)
        let first = states[0]
        let second = states[1]
        let firstBytes = reordered[Int(first.offset)..<Int(first.offset + first.total)]
        let secondBytes = reordered[Int(second.offset)..<Int(second.offset + second.total)]
        reordered.replaceSubrange(
            Int(first.offset)..<Int(second.offset + second.total), with: secondBytes + firstBytes)
        for frame in reorderedWalk.intactRecords where frame.opcode == Opcode.chunkIndex {
            reordered[Int(frame.offset)] = Opcode.privateStart
        }
        let reorderedFooter = try XCTUnwrap(reorderedWalk.firstIntact(Opcode.footer))
        writeU64(0, into: &reordered, at: reorderedFooter.offset + recordHeaderSize)
        writeU32(0, into: &reordered, at: reorderedFooter.offset + recordHeaderSize + 16)
        let reorderedReport = validate(reordered)
        XCTAssertFalse(
            reorderedReport.findings.contains {
                $0.message.hasPrefix("physical state chunks")
            }, "\(reorderedReport.findings.map(\.message))")
    }

    func testKeyframeDeltaAuxiliaryRecordsAreValidatedTogether() throws {
        try requireCorpus()
        let file = corpusDirectory().appendingPathComponent(
            "object/MultiObject-UseChunkIndex-UseCrc.4dgs")
        var bytes = try readFixture(file)
        let walked = try walk(bytes)
        let dispatch = try XCTUnwrap(
            try headerDispatch(ToolReader(InMemoryReader(bytes)), walked))
        bytes.replaceSubrange(
            Int(dispatch.temporalModelOffset)..<Int(dispatch.temporalModelOffset + 14),
            with: "keyframe-delta".utf8)
        let table = try XCTUnwrap(walked.firstIntact(0x24))
        let state = try XCTUnwrap(walked.firstIntact(Opcode.chunk))
        let tableBytes = bytes[Int(table.offset)..<Int(table.offset + table.total)]
        bytes.insert(contentsOf: tableBytes, at: Int(state.offset))

        let report = validate(bytes)
        XCTAssertTrue(
            report.findings.contains {
                $0.message.contains("physical ObjectTable record at byte \(state.offset)")
                    && $0.message.contains("does not decode")
            }, "\(report.findings.map(\.message))")
    }

    func testPhysicalDeltaReferencesAreCheckedWithoutAnIndex() throws {
        try requireCorpus()
        let file = corpusDirectory().appendingPathComponent(
            "keyframe/KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics.4dgs")
        var bytes = try readFixture(file)
        let walked = try walk(bytes)
        let delta = try XCTUnwrap(walked.firstIntact(Opcode.deltaChunk))
        writeU64(
            delta.offset, into: &bytes,
            at: delta.offset + recordHeaderSize + 21)
        for frame in walked.records where frame.opcode == Opcode.chunkIndex {
            bytes[Int(frame.offset)] = Opcode.privateStart
        }
        let footer = try XCTUnwrap(walked.firstIntact(Opcode.footer))
        writeU64(0, into: &bytes, at: footer.offset + recordHeaderSize)
        writeU32(0, into: &bytes, at: footer.offset + recordHeaderSize + 16)

        XCTAssertTrue(
            validate(bytes).findings.contains {
                $0.message.contains("the physical DeltaChunk at byte \(delta.offset)")
                    && $0.message.contains("references point backwards only")
            })
    }

    func testFooterSummaryOffsetStartNamesTheFirstSummaryOffsetRecord() throws {
        try requireCorpus()
        let variant =
            "TenWindows-UseChunkIndex-UseChunks-UseCrc-UseStatistics-UseSummaryOffset.4dgs"
        var bytes = try readFixture(corpusDirectory().appendingPathComponent(variant))
        let walked = try walk(bytes)
        let statistics = try XCTUnwrap(walked.firstIntact(Opcode.statistics))
        let footer = try XCTUnwrap(walked.firstIntact(Opcode.footer))
        writeU64(
            statistics.offset, into: &bytes,
            at: footer.offset + recordHeaderSize + 8)
        writeU32(0, into: &bytes, at: footer.offset + recordHeaderSize + 16)

        XCTAssertTrue(
            validate(bytes).findings.contains {
                $0.message
                    == "the Footer's summary_offset_start \(statistics.offset) names Statistics; "
                    + "expected SummaryOffset"
            })

        var laterOffset = try readFixture(corpusDirectory().appendingPathComponent(variant))
        laterOffset[Int(statistics.offset)] = Opcode.summaryOffset
        writeU32(0, into: &laterOffset, at: footer.offset + recordHeaderSize + 16)
        XCTAssertTrue(
            validate(laterOffset).findings.contains {
                $0.message.contains("does not name the first SummaryOffset record")
                    && $0.message.contains("byte \(statistics.offset)")
            })
    }

}

final class InspectTests: XCTestCase {

    func testASelectiveWalkDoesNotRetainEveryFrame() throws {
        let count = 20_000
        var bytes = magic
        for _ in 0..<count { bytes += [Opcode.privateStart] + littleU64(0) }
        bytes += magic
        let recording = RecordingReader(bytes)
        var visited = 0
        let walked = try walk(
            ToolReader(recording), retaining: { _ in false },
            visit: { _, intact in
                if intact { visited += 1 }
            })

        XCTAssertEqual(visited, count)
        XCTAssertEqual(walked.recordCount, count)
        XCTAssertEqual(walked.intact, count)
        XCTAssertTrue(walked.records.isEmpty)
        XCTAssertEqual(recording.largestRead, Int(recordHeaderSize))
        let report = validate(bytes)
        XCTAssertEqual(report.findings.filter { $0.message.contains("private record") }.count, 1)
        XCTAssertTrue(report.findings.contains { $0.message.contains("20000 private records") })
    }

    func testAWalkFramesEveryRecordAndEndsOnTheMagic() throws {
        try requireCorpus()
        let bytes = try readFixture(corpusDirectory().appendingPathComponent(provenanceVariant))
        let walked = try walk(bytes)
        XCTAssertTrue(walked.trailingMagic)
        XCTAssertNil(walked.cut)
        XCTAssertNotNil(walked.firstIntact(Opcode.header))
        XCTAssertNotNil(walked.firstIntact(Opcode.footer))
        var at = UInt64(magic.count)
        for frame in walked.records {
            XCTAssertEqual(frame.offset, at)
            at += frame.total
        }
        XCTAssertEqual(at, walked.size - UInt64(magic.count))
    }

    func testInspectPrintsOneRowPerRecordAndReportsACut() throws {
        try requireCorpus()
        let file = corpusDirectory().appendingPathComponent(provenanceVariant)
        let whole = runTool(["inspect", file.path])
        XCTAssertEqual(whole.code, exitOk)
        XCTAssertTrue(whole.out.contains("offset  record"))
        XCTAssertTrue(whole.out.contains(" records, "))
        XCTAssertFalse(whole.out.contains("truncated at byte"))
        XCTAssertTrue(whole.out.contains("crc: the Footer's summary checksum covers bytes "))

        let json = runTool(["inspect", "--json", file.path])
        XCTAssertEqual(json.code, exitOk)
        XCTAssertTrue(json.out.contains("\"records\": ["))
        XCTAssertTrue(json.out.contains("\"truncated_at\": null"))
    }

    func testInspectFailsWhenOnlyTheClosingMagicIsMissing() throws {
        try requireCorpus()
        var bytes = try readFixture(corpusDirectory().appendingPathComponent(provenanceVariant))
        bytes.removeLast(magic.count)
        try withTemporaryFile(bytes) { path in
            let result = runTool(["inspect", path])
            XCTAssertEqual(result.code, exitFailed)
            XCTAssertTrue(result.out.contains("note: the file does not end with the magic"))
        }
    }

    func testInspectPreservesMalformedSummaryBounds() throws {
        try requireCorpus()
        var bytes = try readFixture(corpusDirectory().appendingPathComponent(provenanceVariant))
        let walked = try walk(bytes)
        let footer = try XCTUnwrap(walked.firstIntact(Opcode.footer))
        writeU64(footer.offset + 1, into: &bytes, at: footer.offset + recordHeaderSize)

        try withTemporaryFile(bytes) { path in
            let text = runTool(["inspect", path])
            XCTAssertEqual(text.code, exitOk)
            XCTAssertTrue(text.out.contains("crc: INVALID: the Footer's summary starts at"))
            XCTAssertFalse(text.out.contains("declares no summary checksum"))

            let json = runTool(["inspect", "--json", path])
            XCTAssertEqual(json.code, exitOk)
            XCTAssertTrue(json.out.contains("\"summary_crc\": {"))
            XCTAssertTrue(json.out.contains("\"ok\": null"))
        }
    }

    func testInspectClassifiesAMalformedFooterAsAFileFailure() throws {
        try requireCorpus()
        var bytes = try readFixture(corpusDirectory().appendingPathComponent(provenanceVariant))
        let footer = try XCTUnwrap(try walk(bytes).firstIntact(Opcode.footer))
        writeU64(19, into: &bytes, at: footer.offset + 1)

        try withTemporaryFile(bytes) { path in
            let result = runTool(["inspect", path])
            XCTAssertEqual(result.code, exitFailed, result.err)
            XCTAssertTrue(result.err.contains("malformed Footer.fixed fields"), result.err)
        }
    }

    func testTheToolCouldNotRunHasItsOwnExitCode() {
        XCTAssertEqual(runTool(["validate", "/nonexistent-4dgs-file"]).code, exitTool)
        XCTAssertEqual(runTool(["inspect", "/nonexistent-4dgs-file"]).code, exitTool)
        XCTAssertEqual(runTool(["frobnicate", "x"]).code, exitTool)
        XCTAssertEqual(runTool(["validate"]).code, exitTool)
        XCTAssertEqual(runTool(["validate", "--nonsense", "x"]).code, exitTool)
        XCTAssertEqual(runTool(["validate", "--json", "x"]).code, exitTool)
        XCTAssertEqual(runTool(["--help"]).code, exitOk)
        XCTAssertEqual(runTool([]).code, exitOk)
        XCTAssertEqual(runTool(["--version"]).code, exitOk)
    }

    func testAClosedOutputPipeIsSuccessful() {
        let pipe = Pipe()
        pipe.fileHandleForReading.closeFile()
        let out = StandardStream(pipe.fileHandleForWriting)
        out.write("the reader has already left\n")
        XCTAssertTrue(
            out.brokenPipe,
            "failure: \(String(describing: out.failure.map { $0 as NSError }))")

        let diagnostics = Pipe()
        let err = StandardStream(diagnostics.fileHandleForWriting)
        XCTAssertEqual(processExit(exitFailed, out: out, err: err), exitOk)
        diagnostics.fileHandleForWriting.closeFile()
        diagnostics.fileHandleForReading.closeFile()
    }

    func testAnotherOutputFailureRemainsAToolFailure() {
        let closed = Pipe()
        closed.fileHandleForWriting.closeFile()
        let out = StandardStream(closed.fileHandleForWriting)
        out.write("cannot be written")
        XCTAssertNotNil(out.failure)
        XCTAssertFalse(out.brokenPipe)

        let diagnostics = Pipe()
        let err = StandardStream(diagnostics.fileHandleForWriting)
        XCTAssertEqual(processExit(exitOk, out: out, err: err), exitTool)
        diagnostics.fileHandleForWriting.closeFile()
        let message = String(
            data: diagnostics.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        XCTAssertTrue(message?.contains("4dgs: cannot write output:") == true)
        diagnostics.fileHandleForReading.closeFile()
    }
}

final class RefusalPlacementTests: XCTestCase {

    func testAnErrorTheRefusalTableDoesNotNameIsNotGivenAnIdentifier() {
        let truncated = FourDGSError.truncated(
            offset: 0, record: "magic", needed: 8, available: 3)
        XCTAssertNil(describe(truncated, walk: Walk(), site: nil))
    }

    func testAMagicRefusalIsPlacedAtByteZeroWithoutAWalk() throws {
        let error = FourDGSError.notFourDGS(offset: 0, found: [0, 1, 2, 3, 4, 5, 6, 7])
        let named = try XCTUnwrap(describe(error, walk: nil, site: nil))
        XCTAssertEqual(named.code, .magicMismatch)
        XCTAssertEqual(named.site?.offset, 0)
    }

    func testASecondRecordOfTheSameKindLeavesTheRefusalUnplaced() throws {
        let error = FourDGSError.malformed(
            offset: 0, record: "Header", field: "temporal_model", reason: "unknown",
            refusal: .unknownTemporalModel)
        var one = Walk()
        one.records = [Frame(opcode: Opcode.header, offset: 8, length: 10)]
        XCTAssertEqual(try XCTUnwrap(describe(error, walk: one, site: nil)).site?.offset, 8)

        var two = one
        two.records.append(Frame(opcode: Opcode.header, offset: 27, length: 10))
        XCTAssertNil(try XCTUnwrap(describe(error, walk: two, site: nil)).site)
    }

    func testTheDisplayFormCarriesTheCodeAndTheByte() {
        let named = Named(
            code: .unknownTemporalModel, site: Site(offset: 8, what: "the Header record"))
        XCTAssertEqual(
            "\(named)", "refusal unknown-temporal-model at byte 8 (the Header record)")
        XCTAssertEqual("\(Named(code: .unknownStreamCodec, site: nil))", "refusal unknown-stream-codec")
    }

    func testOpcodeNamesCoverTheOpenRanges() {
        XCTAssertEqual(opcodeName(0x01), "Header")
        XCTAssertEqual(opcodeName(0x10), "DeltaChunk")
        XCTAssertEqual(opcodeName(0x25), "ObjectTrack")
        XCTAssertEqual(opcodeName(0x7D), "Unknown(0x7D)")
        XCTAssertEqual(opcodeName(0x91), "Private(0x91)")
        XCTAssertTrue(isSpecified(0x25))
        XCTAssertFalse(isSpecified(0x26))
        XCTAssertTrue(isProvenance(0x26))
        XCTAssertTrue(isPrivate(0x80))
    }

    func testCommasMatchThePythonToolsThousandsSeparator() {
        XCTAssertEqual(commas(0), "0")
        XCTAssertEqual(commas(999), "999")
        XCTAssertEqual(commas(1000), "1,000")
        XCTAssertEqual(commas(9896), "9,896")
        XCTAssertEqual(commas(1_234_567), "1,234,567")
    }

    func testCrc32MatchesTheStandardVector() {
        XCTAssertEqual(crc32(Array("123456789".utf8)[...]), 0xCBF4_3926)
    }

    func testARecordLengthThatWouldWrapIsACut() throws {
        let bytes = magic + [Opcode.header] + [UInt8](repeating: 0xFF, count: 8) + magic
        let walked = try walk(bytes)
        let cut = try XCTUnwrap(walked.cut)
        XCTAssertTrue(cut.insideARecord)
        XCTAssertEqual(cut.at, 8)
        XCTAssertEqual(walked.intact, 0)
        XCTAssertEqual(walked.records[0].total, UInt64.max)
    }
}
