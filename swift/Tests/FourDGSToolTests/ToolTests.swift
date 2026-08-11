// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// The `4dgs` tool, over the corpus that already knows the answers.
///
/// The invalid corpus is seven files, each with a `.json` beside it naming the rule it breaks.
/// That mapping is not restated here: it is read out of the corpus, so this suite cannot drift
/// into agreeing with a stale copy of itself, and a corpus that grows an eighth variant fails this
/// suite until the tool has an answer for it.
///
/// The tool is driven through `run(_:out:err:)` with argument strings and a pair of sinks, which
/// is the whole tool including its exit codes — no subprocess, so this behaves the same wherever
/// the package builds.

import Foundation
import FourDGS
import XCTest

@testable import FourDGSTool

/// One run of the tool: what it printed, and what it exited with.
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

/// A conforming capture carrying provenance records — a coordinate frame, a rig trajectory and
/// sensor calibrations — which is the variant that would produce spurious "unknown record" notes
/// if the provenance family were not recognized.
private let provenanceVariant = "TenWindows-UseChunkIndex-UseCrc-WithFrame-WithRig-WithSensors.4dgs"

/// Where the generated corpus lives. Located from this file rather than from the working
/// directory, because `swift test` does not promise one.
private func corpusDirectory() -> URL {
    if let fromEnvironment = ProcessInfo.processInfo.environment["FOURDGS_CORPUS"] {
        return URL(fileURLWithPath: fromEnvironment)
    }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { root.deleteLastPathComponent() }
    return root.appendingPathComponent("tests/conformance/data")
}

/// Skip when the corpus is not on disk.
///
/// The corpus is generated rather than committed, so a developer who has not run the generator
/// gets skipped tests instead of failures — but CI generates it before this suite runs, and there
/// a missing corpus is a suite that silently did not run.
private func requireCorpus() throws {
    let invalid = corpusDirectory().appendingPathComponent("invalid")
    if FileManager.default.fileExists(atPath: invalid.path) { return }
    if ProcessInfo.processInfo.environment["CI"] != nil {
        XCTFail("the corpus is missing; run tests/conformance/generate.py")
        return
    }
    throw XCTSkip("no corpus; run tests/conformance/generate.py first")
}

/// Every `.4dgs` in a corpus directory, sorted so a failure names the same file twice running.
private func variants(_ directory: URL) -> [URL] {
    let found = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return
        found
        .filter { $0.hasSuffix(".4dgs") }
        .sorted()
        .map { directory.appendingPathComponent($0) }
}

/// Tests deliberately mutate tiny corpus fixtures in memory. Production commands never use this.
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

private func littleU64(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
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

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    func byteCount() throws -> Int64 { Int64(bytes.count) }

    func read(offset: Int64, count: Int) throws -> [UInt8] {
        largestRead = max(largestRead, count)
        let start = min(Int(clamping: offset), bytes.count)
        let end = min(start + count, bytes.count)
        return Array(bytes[start..<end])
    }
}

/// The `"refused"` member of an expectation file: the identifier the corpus says a reader must
/// produce for these bytes.
private func expectedRefusal(_ variant: URL) -> String? {
    let json = variant.deletingPathExtension().appendingPathExtension("json")
    guard let data = FileManager.default.contents(atPath: json.path),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object["refused"] as? String
}

final class ValidateTests: XCTestCase {

    /// The strongest evidence there is that this tool is right, because the corpus already knows
    /// the answer and the tool had no hand in writing it. "Refused" alone is not the property: a
    /// reader that refuses every one of these for the wrong reason passes a test that only checks
    /// the exit code, and that is precisely the failure the invalid corpus was built to catch.
    func testEveryInvalidVariantIsRefusedByItsOwnIdentifier() throws {
        try requireCorpus()
        let files = variants(corpusDirectory().appendingPathComponent("invalid"))
        XCTAssertEqual(files.count, 7)
        for file in files {
            let code = try XCTUnwrap(expectedRefusal(file), "\(file.lastPathComponent)")
            let result = runTool(["validate", file.path])
            // Non-zero, and this non-zero: 3 would mean the tool could not read the file at all.
            XCTAssertEqual(result.code, exitFailed, "\(file.lastPathComponent)")
            // And the byte, which is the question its holder actually has. Every one of these is
            // placeable: four in the front matter, two inside a chunk the tool decodes.
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
        // Provenance records are specified records, not unknown ones. Reporting them as unknown
        // would put four notes on every conforming capture that Python says nothing about.
        XCTAssertFalse(result.out.contains("unknown record"))
        XCTAssertFalse(result.out.contains("error:"))
    }

    /// It is not, in the Python validator: every structural check there assumes the
    /// gaussian-birth chunk shape, so a file whose Chunks are keyframes and whose Delta Chunks
    /// are differences comes back invalid. This tool recognizes that shape and applies its own
    /// two-kind index rule instead of sending it through the wrong reader.
    func testAConformingKeyframeDeltaFileIsValid() throws {
        try requireCorpus()
        let files = variants(corpusDirectory().appendingPathComponent("keyframe"))
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let result = runTool(["validate", file.path])
            XCTAssertEqual(result.code, exitOk, "\(file.lastPathComponent) said: \(result.out)")
            XCTAssertFalse(result.out.contains("error:"), result.out)
        }
    }

    /// The other half of the corpus's evidence: a validator that refused everything would pass
    /// the check above and fail this one.
    func testEveryValidVariantIsValid() throws {
        try requireCorpus()
        // The object-layer variants live in their own directory and are conforming files like any
        // other; a validator that only ever saw the flat directory would not know that.
        let files =
            variants(corpusDirectory()) + variants(corpusDirectory().appendingPathComponent("object"))
        XCTAssertGreaterThanOrEqual(files.count, 40)
        for file in files {
            let result = runTool(["validate", file.path])
            // 0, or 2 for a variant that carries no chunk index and warns about it. Never 1.
            XCTAssertTrue(
                result.code == exitOk || result.code == exitWarnings,
                "\(file.lastPathComponent) said: \(result.out)")
        }
    }

    /// A band that will not decode is a file that will not decode.
    ///
    /// Spherical harmonics do not enter reconstructed state, so a *renderer* is right to cap them
    /// — but an SH Band Stream is a stream like any other, and a scan that capped the bands would
    /// report this file `valid` while a reader asked for its harmonics refuses it. The corpus has
    /// no variant for it, so this makes one the way `tests/conformance/generator/invalid.py` makes
    /// its own: one byte, length-preserving, breaking exactly one rule. A stream's codec is the
    /// fourth byte of its header (spec §5.5), one past the band number an SH Band Stream record
    /// opens with (§5.7), and the registry reserves 4-127 — so 9 is legal-but-unimplemented rather
    /// than nonsense.
    func testABandThatWillNotDecodeIsRefusedAndPlacedAtItsOwnRecord() throws {
        try requireCorpus()
        let variant = "MixedLifetimes-SHDegree3-UseChunkIndex-UseCrc.4dgs"
        var bytes = try readFixture(corpusDirectory().appendingPathComponent(variant))
        XCTAssertTrue(validate(bytes).ok, "the unpatched variant is a conforming file")

        let walked = try walk(bytes)
        let bands = walked.records.filter { $0.opcode == 0x07 }
        XCTAssertGreaterThanOrEqual(bands.count, 3)
        // The second band record of the first chunk, so the narrowing has to walk past a band that
        // decodes before it reaches the one that does not.
        let band = bands[1]
        bytes[Int(band.offset + recordHeaderSize) + 4] = 9

        let report = validate(bytes)
        XCTAssertFalse(report.ok, "a band that does not decode is not a valid file")
        let refusal = try XCTUnwrap(report.findings.compactMap(\.refusal).first)
        XCTAssertEqual(refusal.code, .unknownStreamCodec)
        // The band's own record, not the Chunk thousands of bytes away.
        XCTAssertEqual(refusal.site?.offset, band.offset)
        XCTAssertEqual(
            refusal.site?.what, "the SH Band Stream for band 2 of the Chunk at index entry 0")
    }

    /// A cut file is invalid and every finding stands — but records are length-prefixed, so what
    /// is complete before the cut is intact, and how much of it survived is the question its
    /// holder actually has.
    func testACutFileReportsTheIntactPrefixAndTheByte() throws {
        try requireCorpus()
        let bytes = try readFixture(corpusDirectory().appendingPathComponent(provenanceVariant))
        let whole = try walk(bytes)
        let cutBytes = Array(bytes.prefix(bytes.count / 2))
        let cut = try walk(cutBytes)
        let where_ = try XCTUnwrap(cut.cut)
        XCTAssertLessThan(where_.at, UInt64(cutBytes.count))
        XCTAssertFalse(cut.trailingMagic)
        // The intact prefix is still framed, and the record the file was cut inside is reported
        // but is not part of it: hiding that record would hide the declared length that is the
        // fault.
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

    /// Even with no intact first record, the length-prefixed frame identifies the exact fault.
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

    /// An index is untrusted bytes. `offset == size, length == 0` passes an end-only bound but
    /// names the byte after the file; that must be a finding, never an array trap.
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

    /// A range is not proved by fitting inside the resource. It must be exactly the whole framed
    /// record, or an indexed decoder can materialize unrelated trailing bytes under an
    /// attacker-sized `chunk_length`.
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

    /// An index may not hide physical data by naming only a subset. The unknown codec lives in the
    /// first Chunk; redirecting its entry to the second makes that Chunk absent from the index, so
    /// only the bounded physical scan can still find the refusal.
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

    /// A matching checksum does not make arbitrary records into summary records. The three legal
    /// kinds are a structural rule of §4.5, independently of CRC integrity.
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

    func testKeyframeDeltaIndexDiagnosticNamesBothLegalTargets() throws {
        try requireCorpus()
        let file = try XCTUnwrap(
            variants(corpusDirectory().appendingPathComponent("keyframe")).first)
        var bytes = try readFixture(file)
        let walked = try walk(bytes)
        let frame = try XCTUnwrap(walked.firstIntact(Opcode.chunkIndex))
        // Point the first entry at the Header: in bounds, but neither legal chunk kind.
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

    /// A Header string has a u32 length, not a 4 KiB limit. Dispatch follows those lengths with
    /// small range reads, so a producer's long free-form name cannot hide `temporal_model`.
    func testKeyframeDeltaDispatchReadsPastALongHeaderPrefix() throws {
        let longLibrary = [UInt8](repeating: 0x61, count: 5000)
        var content = littleU32(0)  // profile
        content += littleU32(UInt32(longLibrary.count)) + longLibrary
        content += [UInt8](repeating: 0, count: 24)  // duration, gaussian count, cutoff
        let model = Array("keyframe-delta".utf8)
        content += littleU32(UInt32(model.count)) + model
        let bytes = magic + [Opcode.header] + littleU64(UInt64(content.count)) + content + magic
        let recording = RecordingReader(bytes)
        let source = ToolReader(recording)
        let walked = try walk(source, retaining: { $0.opcode == Opcode.header })

        XCTAssertTrue(try isKeyframeDelta(source, walked))
        XCTAssertEqual(recording.largestRead, model.count)
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

    /// The CLI's structural work stays on ranges for both temporal models. These fixtures are
    /// larger than the bounded Header prefix, so a file-sized request would be visible here.
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
            XCTAssertTrue(report.ok, "\(file.lastPathComponent): \(report.findings.map(\.message))")
            XCTAssertLessThan(recording.largestRead, bytes.count, file.lastPathComponent)
        }
    }
}

final class InspectTests: XCTestCase {

    /// The production walk can visit an arbitrary record stream without retaining its frames.
    /// The fixture is intentionally dominated by zero-length private records: retaining a Frame
    /// per record is exactly the old file-size-multiplier failure mode.
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
    }

    func testAWalkFramesEveryRecordAndEndsOnTheMagic() throws {
        try requireCorpus()
        let bytes = try readFixture(corpusDirectory().appendingPathComponent(provenanceVariant))
        let walked = try walk(bytes)
        XCTAssertTrue(walked.trailingMagic)
        XCTAssertNil(walked.cut)
        XCTAssertNotNil(walked.firstIntact(Opcode.header))
        XCTAssertNotNil(walked.firstIntact(Opcode.footer))
        // Every record accounted for, back to back: the offsets have to tile the file.
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
        // The summary checksum is a fact about a region, so the covered range is named beneath
        // the table rather than left for the reader to infer from the column.
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

    /// `1` is an answer about a file: it was read, and it is bad. `3` is the absence of an answer,
    /// and a pipeline that saw `1` for both could not tell a corrupt asset from a typo in a path.
    func testTheToolCouldNotRunHasItsOwnExitCode() {
        XCTAssertEqual(runTool(["validate", "/nonexistent-4dgs-file"]).code, exitTool)
        XCTAssertEqual(runTool(["inspect", "/nonexistent-4dgs-file"]).code, exitTool)
        XCTAssertEqual(runTool(["frobnicate", "x"]).code, exitTool)
        XCTAssertEqual(runTool(["validate"]).code, exitTool)
        XCTAssertEqual(runTool(["validate", "--nonsense", "x"]).code, exitTool)
        XCTAssertEqual(runTool(["validate", "--json", "x"]).code, exitTool)
        // A request that was served is not a failure.
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

    /// A truncated transport is a real error and not a refusal. Inventing a code for it would be
    /// inventing conformance.
    func testAnErrorTheRefusalTableDoesNotNameIsNotGivenAnIdentifier() {
        let truncated = FourDGSError.truncated(
            offset: 0, record: "magic", needed: 8, available: 3)
        XCTAssertNil(describe(truncated, walk: Walk(), site: nil))
    }

    /// And a refusal about the magic is placed at byte zero without a walk, because the walk that
    /// would find a record cannot start until the magic passes.
    func testAMagicRefusalIsPlacedAtByteZeroWithoutAWalk() throws {
        let error = FourDGSError.notFourDGS(offset: 0, found: [0, 1, 2, 3, 4, 5, 6, 7])
        let named = try XCTUnwrap(describe(error, walk: nil, site: nil))
        XCTAssertEqual(named.code, .magicMismatch)
        XCTAssertEqual(named.site?.offset, 0)
    }

    /// An ambiguous file gets the identifier without a byte. Nothing forbids a second Header, the
    /// reader refuses at the first one carrying a value it does not implement, and this package
    /// has no record parser to tell them apart — so it says nothing rather than naming a record
    /// that may be perfectly good.
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
        // The two ranges the specification leaves open, told apart because the fix differs: a
        // private record is somebody else's business and an unknown one is a later revision's.
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

    /// CRC-32 (IEEE), against the vector every implementation of it is checked with.
    func testCrc32MatchesTheStandardVector() {
        XCTAssertEqual(crc32(Array("123456789".utf8)[...]), 0xCBF4_3926)
    }

    /// A declared length that would wrap `UInt64` is reported as a record running past the end
    /// rather than as a total that fits — which is what a saturating add is for.
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
