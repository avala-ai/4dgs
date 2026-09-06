// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// A constant-memory top-level framing pass for the placement rule in spec section 4.
///
/// The current Linux core enforces this itself. Apple SwiftPM consumers, however, link the
/// already-published 0.7.1 XCFramework, which predates the rule and exposes no ABI for its two
/// record sites. Keeping the check at the Swift edge makes explicit streamed reads agree on every
/// platform without parsing record bodies or changing indexed open's permitted early stop.
enum StreamedRecordPlacement {
    private static let magicSize: Int64 = 8
    private static let recordHeaderSize: Int64 = 9

    static func validate(_ source: any ByteRangeReader) throws {
        var reader = source
        let size = try reader.byteCount()
        guard size >= magicSize else { return }

        let prefix = try reader.read(offset: 0, count: Int(magicSize))
        guard prefix == Core.magic else { return }

        var firstState: RecordSite?
        var offset = magicSize
        while offset < size {
            let remaining = size - offset
            // Eight bytes at the end are the trailing magic. Any other short tail or a short
            // transport read belongs to the core's established truncation diagnosis.
            guard remaining > magicSize, remaining >= recordHeaderSize else { return }
            let header = try reader.read(offset: offset, count: Int(recordHeaderSize))
            guard header.count == Int(recordHeaderSize) else { return }

            let opcode = header[0]
            let site = RecordSite(opcode: opcode, offset: UInt64(offset))
            // Placement is known from the complete record header. It takes precedence over
            // parsing or even transferring the late body, including when that body's declared
            // length runs past EOF.
            if let firstState, isDefinedFrontMatter(opcode) {
                throw FourDGSError.lateFrontMatterRecord(
                    records: LateFrontMatterRecords(
                        lateRecord: site, firstStateRecord: firstState))
            }
            if firstState == nil, isState(opcode) { firstState = site }

            var contentLength: UInt64 = 0
            for index in (1..<9).reversed() {
                contentLength = (contentLength << 8) | UInt64(header[index])
            }
            let bytesAfterHeader = remaining - recordHeaderSize
            guard contentLength <= UInt64(bytesAfterHeader) else { return }

            guard let signedLength = Int64(exactly: contentLength) else { return }
            offset += recordHeaderSize + signedLength
        }
    }

    private static func isState(_ opcode: UInt8) -> Bool {
        opcode == 0x05 || opcode == 0x10
    }

    /// The closed set from the record-placement registry. Unknown and private records keep their
    /// skip semantics and deliberately do not become front matter by falling in a numeric range.
    private static func isDefinedFrontMatter(_ opcode: UInt8) -> Bool {
        switch opcode {
        case 0x01, 0x03, 0x04, 0x09, 0x0A, 0x0B, 0x0D, 0x11, 0x12, 0x20...0x25:
            return true
        default:
            return false
        }
    }
}
