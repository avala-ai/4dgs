// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Which record is where, which refusal fired, and at which byte.
///
/// The package already names its refusals — ``FourDGS/FourDGSError/refusalCode`` returns the
/// identifier the conformance corpus is written against — and the core's messages already say
/// which value was found and what was expected. What neither of them carries is the **offset**:
/// an error is raised where the value was parsed, not where the bytes sit, and by then the
/// record's position is several frames down the call stack, on the other side of an ABI.
///
/// So the tool supplies it. The refusal vocabulary is six identifiers, each of which is about
/// exactly one kind of record, and a framing walk knows where every record is. That is the whole
/// mechanism: walk the framing, ask which record this refusal is about, print the byte.
///
/// Front matter is located from framing alone. A refusal that lives inside a chunk's streams is
/// located by decoding chunks one at a time until one of them refuses, which is also the only way
/// to *find* those refusals at all — the framing walk steps over a chunk by its declared length
/// and never looks inside it, which is why a framing-only validator calls two of the invalid
/// corpus's seven files clean.

import FourDGS

/// The eight bytes a 4dgs file opens and closes with (spec §4.1).
///
/// Written out here rather than borrowed from the SDK because framing is this tool's own job:
/// `inspect` walks records without opening a scene, and the sentinel is the one part of the
/// format that never moves.
public let magic: [UInt8] = [0x89, 0x34, 0x44, 0x47, 0x53, 0x31, 0x0D, 0x0A]
/// `u8` opcode plus `u64` content length.
public let recordHeaderSize: UInt64 = 9

/// The record opcodes this tool names by hand, spec §5.2.
///
/// Only the ones it reasons about: the front matter a refusal is placed against, the two chunk
/// kinds, the index and the two open ranges. A tool that walks framing has to know them to walk
/// anything.
public enum Opcode {
    public static let header: UInt8 = 0x01
    public static let footer: UInt8 = 0x02
    public static let quantization: UInt8 = 0x03
    public static let windowTable: UInt8 = 0x04
    public static let chunk: UInt8 = 0x05
    public static let shBandStream: UInt8 = 0x07
    public static let chunkIndex: UInt8 = 0x08
    public static let statistics: UInt8 = 0x0C
    public static let summaryOffset: UInt8 = 0x0F
    /// A keyframe-delta file's delta chunks. Deliberately not a flag on Chunk: a Chunk is
    /// independently decodable and a Delta Chunk is exactly the record that is not.
    public static let deltaChunk: UInt8 = 0x10
    public static let audioData: UInt8 = 0x12
    public static let coordinateFrame: UInt8 = 0x20
    public static let objectTrack: UInt8 = 0x25
    /// One past the provenance family's last reserved opcode.
    public static let provenanceEnd: UInt8 = 0x30
    /// First opcode of the application range, which this specification never defines.
    public static let privateStart: UInt8 = 0x80
}

/// A human name for an opcode, in the vocabulary of `concepts.md`. `Unknown(0xNN)` and
/// `Private(0xNN)` for the two ranges this specification leaves open.
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

/// The application range `0x80`-`0xFF`, which the specification never defines.
public func isPrivate(_ opcode: UInt8) -> Bool { opcode >= Opcode.privateStart }

/// The provenance family `0x20`-`0x2F`, defined and reserved alike.
public func isProvenance(_ opcode: UInt8) -> Bool {
    opcode >= Opcode.coordinateFrame && opcode < Opcode.provenanceEnd
}

/// True for the opcodes the specification defines. Everything else is either the application
/// range or a record from a revision this build does not implement, and both are skipped rather
/// than refused.
public func isSpecified(_ opcode: UInt8) -> Bool {
    (opcode >= Opcode.header && opcode <= Opcode.audioData)
        || (opcode >= Opcode.coordinateFrame && opcode <= Opcode.objectTrack)
}

/// Two uppercase hex digits, for the opcode ranges the specification leaves open.
public func hex2(_ value: UInt8) -> String {
    let digits = Array("0123456789ABCDEF")
    return String(digits[Int(value >> 4)]) + String(digits[Int(value & 0x0F)])
}

/// A count with thousands separators, matching the Python tool's `{:,}`.
public func commas(_ value: UInt64) -> String {
    let digits = Array(String(value))
    var out = ""
    for (i, digit) in digits.enumerated() {
        if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
        out.append(digit)
    }
    return out
}

/// CRC-32 (IEEE), the polynomial the Footer declares its summary under.
///
/// Written out rather than reached for, exactly as the conformance helper writes it out: a
/// checksum is fifteen lines and a dependency is forever.
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

/// The tool's one transport edge.
///
/// `ByteRangeReader` has mutating requirements so value transports can keep cursor or cache state.
/// Boxing it once lets framing, checksum validation and the decoder share that abstraction without
/// ever turning a file into an array. Tests can still put an `InMemoryReader` behind the same box.
final class ToolReader: ByteRangeReader {
    private var base: any ByteRangeReader

    init(_ base: any ByteRangeReader) { self.base = base }

    func byteCount() throws -> Int64 { try base.byteCount() }

    func read(offset: Int64, count: Int) throws -> [UInt8] {
        try base.read(offset: offset, count: count)
    }

    /// A non-negative size. The protocol uses `Int64`, so every valid offset also fits its reads.
    func size() throws -> UInt64 {
        let count = try byteCount()
        guard count >= 0 else { throw FourDGSError.invalidRange(offset: count, count: 0) }
        return UInt64(count)
    }

    /// Exactly one already-bounded range, or the SDK's ordinary truncation diagnosis.
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

/// One record's framing: what it is, where it starts, how long its content is.
public struct Frame: Equatable {
    public let opcode: UInt8
    /// Offset of the opcode byte.
    public let offset: UInt64
    /// Content length, as the record declares it.
    public let length: UInt64

    /// Framing plus content, which is what an offset has to advance by.
    ///
    /// Saturating: the length is eight bytes off an untrusted file, so a record can declare
    /// `UInt64.max` and this is where that would wrap. Saturating produces a total that runs
    /// past the end of any file, which is exactly what the walk then reports.
    public var total: UInt64 {
        let (total, overflow) = length.addingReportingOverflow(recordHeaderSize)
        return overflow ? UInt64.max : total
    }

    var overflows: Bool { length.addingReportingOverflow(recordHeaderSize).overflow }
}

/// Where a framing walk stopped, when it did not reach the end.
public struct Cut {
    /// The first byte the walk could not account for.
    public let at: UInt64
    public let reason: String
    /// True when the cut is inside a record whose framing was read — so the last record the walk
    /// reports is the incomplete one, and everything before it is intact.
    public let insideARecord: Bool
}

/// The result of walking a file's framing: counts, retained metadata, and the cut if there was one.
///
/// `records` is deliberately not necessarily the whole walk. Production callers retain only the
/// few record kinds they need after the scan; a visitor sees every frame while it is current. The
/// in-memory convenience below retains everything for focused parser tests.
public struct Walk {
    public var records: [Frame] = []
    public var cut: Cut?
    /// True when the last eight bytes are the magic, as a whole file's are.
    public var trailingMagic = false
    public var size: UInt64 = 0
    /// Every framed record, whether retained in ``records`` or not.
    public var recordCount = 0
    fileprivate var intactRecordCount = 0
    fileprivate var retainedIntactCount = 0

    /// The retained records a streamed reader keeps. A record cut inside can be retained so its
    /// declared length remains reportable, but it is never in this slice.
    public var intactRecords: ArraySlice<Frame> {
        // The fallback preserves the useful value semantics of a hand-built `Walk` in focused
        // tests and callers: scanner-produced walks always have a nonzero `recordCount` when they
        // carry records, while a literal can only express the old all-retained shape.
        let count =
            recordCount == 0 && !records.isEmpty
            ? records.count - ((cut?.insideARecord ?? false) ? 1 : 0)
            : retainedIntactCount
        return records.prefix(count)
    }

    /// The first *whole* record with this opcode, or `nil`.
    ///
    /// Whole is the only useful sense here. The walk also reports the record a file was cut
    /// inside — its declared length is the fault, and hiding the record would hide the field that
    /// carries it — but that record's content is not in the file, so a caller that means to read
    /// one must not be handed it.
    public func firstIntact(_ opcode: UInt8) -> Frame? {
        intactRecords.first { $0.opcode == opcode }
    }

    /// How many of all framed records are whole, including frames the caller did not retain.
    ///
    /// All of them, except when the file was cut inside one: that record is reported — hiding it
    /// would hide the declared length that is the whole fault — but it is not something a
    /// streamed reader keeps.
    public var intact: Int {
        recordCount == 0 && !records.isEmpty
            ? records.count - ((cut?.insideARecord ?? false) ? 1 : 0)
            : intactRecordCount
    }
}

/// A little-endian `u64` at `at`, or `nil` when the bytes are not there.
func readU64(_ bytes: [UInt8], at: UInt64) -> UInt64? {
    guard at <= UInt64(bytes.count), UInt64(bytes.count) - at >= 8 else { return nil }
    let start = Int(at)
    var value: UInt64 = 0
    for i in (0..<8).reversed() { value = (value << 8) | UInt64(bytes[start + i]) }
    return value
}

/// A little-endian `u32` at `at`, or `nil` when the bytes are not there.
func readU32(_ bytes: [UInt8], at: UInt64) -> UInt32? {
    guard at <= UInt64(bytes.count), UInt64(bytes.count) - at >= 4 else { return nil }
    let start = Int(at)
    var value: UInt32 = 0
    for i in (0..<4).reversed() { value = (value << 8) | UInt32(bytes[start + i]) }
    return value
}

/// A little-endian `u16` at `at`, or `nil` when the bytes are not there.
func readU16(_ bytes: [UInt8], at: UInt64) -> UInt16? {
    guard at <= UInt64(bytes.count), UInt64(bytes.count) - at >= 2 else { return nil }
    let start = Int(at)
    return UInt16(bytes[start]) | (UInt16(bytes[start + 1]) << 8)
}

/// A little-endian IEEE-754 `f64` at `at`, or `nil` when the bytes are not there.
func readF64(_ bytes: [UInt8], at: UInt64) -> Double? {
    readU64(bytes, at: at).map(Double.init(bitPattern:))
}

/// Every top-level record, from framing alone.
///
/// Reads nine bytes per record and steps over the content, so this is as cheap on a file carrying
/// an hour of audio as on one carrying none. The magic is checked first, because a walk over
/// bytes that are not ours would report whatever the first byte happened to mean as an opcode —
/// and when it fails, the SDK is asked to name the refusal so that the wording and the identifier
/// are the reader's rather than this tool's.
///
/// `retaining` chooses the bounded metadata needed after the scan. `visit` receives every frame
/// while it is current, including the final incomplete one; its Boolean says whether the record
/// is whole. This is what lets `inspect` emit an arbitrarily long record list without storing it.
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
        // A whole file ends with the magic, so its last eight bytes are not a record.
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
            // An incomplete record is still visited and may be retained: its declared length is
            // the fault, and hiding the record would hide the field that carries it.
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

/// Retain every frame. This exists for callers that explicitly want an in-memory walk; the CLI
/// uses the selective overload above so file size cannot turn into frame-array size.
func walk(_ source: ToolReader) throws -> Walk {
    try walk(source, retaining: { _ in true })
}

/// The in-memory convenience used by unit tests and callers that already own their bytes.
public func walk(_ bytes: [UInt8]) throws -> Walk {
    try walk(ToolReader(InMemoryReader(bytes)))
}

/// Ask the SDK to name a bad magic, so the wording and the identifier are the reader's.
///
/// Only reached once the eight bytes have already been found not to be ours, and only over the
/// prefix: `SceneReader` checks the magic before it needs another byte, so eight bytes are enough
/// to get the diagnosis without opening a file this tool has just refused.
///
/// Two refusals live here and telling them apart is the reader's job, not this tool's: every byte
/// of the magic except one is a fixed sentinel, so a file that differs elsewhere is not a 4dgs
/// file whatever its version byte says, while a file that differs only there wants a newer reader.
/// Guessing between them sends somebody looking for a build that would not have helped.
func refuseMagic(_ bytes: [UInt8]) -> FourDGSError {
    let head = Array(bytes.prefix(magic.count))
    do {
        _ = try SceneReader(InMemoryReader(head))
    } catch let error as FourDGSError {
        return error
    } catch {
        return .unreadableSource(description: "\(error)")
    }
    return .notFourDGS(offset: 0, found: head)
}

/// The byte a refusal fired at, and what sits there.
public struct Site {
    public let offset: UInt64
    /// What the offset points at, in the vocabulary of `concepts.md`.
    public let what: String

    public init(offset: UInt64, what: String) {
        self.offset = offset
        self.what = what
    }
}

/// A refusal with a name, and where it is if the tool could place it.
public struct Named: CustomStringConvertible {
    /// The identifier the specification and the conformance corpus use.
    public let code: RefusalCode
    public let site: Site?

    /// `refusal unknown-temporal-model at byte 8 (the Header record)`.
    public var description: String {
        guard let site else { return "refusal \(code.rawValue)" }
        return "refusal \(code.rawValue) at byte \(site.offset) (\(site.what))"
    }
}

/// Which record a named refusal is about.
///
/// A table rather than a guess, and a short one because the refusal vocabulary is short. A code
/// this build cannot place is left unplaced rather than placed wrongly — an offset that points at
/// the wrong record is worse than no offset, because the reader believes it.
///
/// **Only when the file carries one of them.** Nothing in the framing forbids a second Header or
/// a second Quantization record, and both read paths check every copy they meet as they meet it —
/// so a file whose first Header is fine and whose second declares a model this build does not
/// implement is refused at the *second*. Telling those apart means parsing each candidate's
/// content and asking the registry about the value it declares, which is a record parser and a
/// registry this package deliberately does not have: it is a binding, and the one decoder lives
/// in the core. So an ambiguous file gets the identifier without a byte, which is the honest
/// answer, rather than the offset of a record that may be perfectly good.
func frontMatterSite(_ walk: Walk?, _ code: RefusalCode) -> Site? {
    let opcode: UInt8
    let what: String
    switch code {
    // Both of these are about the eight bytes of the magic itself, which is why neither needs a
    // walk to place: the walk that would find a record cannot start until they pass, and the
    // offset is known without one.
    case .magicMismatch, .unsupportedMajorVersion:
        return Site(offset: 0, what: "the magic")
    case .unknownTemporalModel:
        opcode = Opcode.header
        what = "the Header record"
    case .unknownQuantizationScheme:
        opcode = Opcode.quantization
        what = "the Quantization record"
    // Both live inside a chunk's streams, where only a decode finds them; `scanChunks` supplies
    // the site because it knows which chunk and which band it was decoding.
    case .unknownStreamCodec, .windowIndexOutOfRange:
        return nil
    }
    guard let walk else { return nil }
    let candidates = walk.intactRecords.filter { $0.opcode == opcode }
    guard candidates.count == 1, let frame = candidates.first else { return nil }
    return Site(offset: frame.offset, what: what)
}

/// Everything the tool can say about one refusal: the identifier and the byte.
///
/// `nil` for an error the refusal table does not name — a truncated transport, a bad range. That
/// is not a failure of this function; it is the SDK saying "this is not one of the refusals the
/// corpus compares", and a tool that invented an identifier there would be inventing conformance.
public func describe(_ error: FourDGSError, walk: Walk?, site: Site?) -> Named? {
    guard let code = error.refusalCode else { return nil }
    return Named(code: code, site: site ?? frontMatterSite(walk, code))
}

/// One Chunk Index entry, including the keyframe-delta fields when the record carries them.
public struct IndexEntry {
    public let t0: Double
    public let t1: Double
    public let offset: UInt64
    public let length: UInt64
    /// `(band, offset, length)` for each SH Band Stream record this chunk's harmonics live in. A
    /// chunk is not one record: the Chunk carries the attribute streams and each band sits in a
    /// record of its own, elsewhere in the file, which is what lets a capped reader skip a band by
    /// byte range rather than by decoding it.
    public let bands: [(band: UInt8, offset: UInt64, length: UInt64)]
    /// Whether the keyframe-delta block appended after the variable band table was present.
    public let extended: Bool
    /// 0 for a keyframe Chunk, 1 for a Delta Chunk.
    public let kind: UInt8
    public let deltaMode: UInt8
    public let referenceOffset: UInt64
    public let keyframeOffset: UInt64
    public let depth: UInt16
    public let liveCount: UInt64
}

/// What the file's own index says about where its chunks and their bands are, in index order.
///
/// Read from the Chunk Index records rather than from the Chunk records the walk found, because
/// "index entry 3" is what the reader was asked for and what it will name back — and because an
/// entry pointing somewhere there is no Chunk is one of the things a validator is for.
///
/// A bounded parse of the fixed prefix, the small band-address table, and the optional
/// keyframe-delta block (spec §5.8). No record-sized allocation is made: the parser reads the
/// forty-byte prefix, at most three useful band entries, and the fixed twenty-eight-byte extension.
func chunkIndexEntries(_ source: ToolReader, _ walk: Walk) throws -> [IndexEntry] {
    let t0Field: UInt64 = 0
    let t1Field: UInt64 = 8
    let offsetField: UInt64 = 16
    let bandCountField: UInt64 = 36
    let prefix: UInt64 = 40
    let bandEntrySize: UInt64 = 17
    let deltaBlockSize: UInt64 = 28
    var out: [IndexEntry] = []
    for frame in walk.intactRecords where frame.opcode == Opcode.chunkIndex {
        let content = frame.offset + recordHeaderSize
        guard frame.length >= prefix else { continue }
        let fields = try source.exactly(
            offset: content, count: Int(prefix), record: "Chunk Index")
        guard let t0 = readF64(fields, at: t0Field), let t1 = readF64(fields, at: t1Field),
            let offset = readU64(fields, at: offsetField),
            let length = readU64(fields, at: offsetField + 8)
        else { continue }
        var bands: [(band: UInt8, offset: UInt64, length: UInt64)] = []
        let declared = UInt64(readU32(fields, at: bandCountField) ?? 0)
        // `(u8 band, u64 offset, u64 length)` each, and only as many as this record's own
        // declared length has room for. Degree 3 is the format maximum, so at most three bands
        // can be useful for refusal placement; the count is four bytes off an untrusted file.
        var at = content + prefix
        let available = (frame.length - prefix) / bandEntrySize
        for _ in 0..<min(min(declared, available), 3) {
            let field = try source.exactly(
                offset: at, count: Int(bandEntrySize), record: "Chunk Index band range")
            guard let bandOffset = readU64(field, at: 1), let bandLength = readU64(field, at: 9)
            else { break }
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
                t0: t0, t1: t1, offset: offset, length: length, bands: bands,
                extended: hasExtension, kind: kind, deltaMode: deltaMode,
                referenceOffset: referenceOffset, keyframeOffset: keyframeOffset, depth: depth,
                liveCount: liveCount))
    }
    return out
}

/// The in-memory convenience used by focused parser tests.
public func chunkIndexEntries(_ bytes: [UInt8], _ walk: Walk) -> [IndexEntry] {
    (try? chunkIndexEntries(ToolReader(InMemoryReader(bytes)), walk)) ?? []
}

/// Whether the first whole Header declares `keyframe-delta`, using only bounded ranges.
///
/// The two strings before `temporal_model` have no small length cap, so a fixed prefix cannot
/// reach the model in every conforming Header. Their four-byte lengths are enough to skip them;
/// only the model itself is read, and only when it has exactly the fourteen bytes needed to equal
/// the one value this validator dispatches specially. A malformed Header returns `false` here and
/// is diagnosed by the ordinary gaussian-birth reader rather than by a second Header parser.
func isKeyframeDelta(_ source: ToolReader, _ walk: Walk) throws -> Bool {
    guard let frame = walk.firstIntact(Opcode.header) else { return false }
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

    guard let profileLength = try stringLength() else { return false }
    relative += profileLength
    guard let libraryLength = try stringLength() else { return false }
    relative += libraryLength

    // duration_sec, gaussian_count, cutoff.
    let fixed: UInt64 = 24
    guard relative <= frame.length, frame.length - relative >= fixed else { return false }
    relative += fixed
    guard let modelLength = try stringLength() else { return false }
    let expected = Array("keyframe-delta".utf8)
    guard modelLength == UInt64(expected.count) else { return false }
    let model = try source.exactly(
        offset: content + relative, count: expected.count, record: "Header temporal_model")
    return model == expected
}

/// What the Footer declares about the summary checksum, and where the summary ends.
public struct SummaryDeclaration {
    /// First byte the checksum covers.
    public let start: UInt64
    public let crc: UInt32
    /// One past the last covered byte: where the Footer record's opcode sits.
    public let end: UInt64
}

/// Empty when the file has no Footer, or declares no summary checksum — which is a property of
/// the file rather than a failure, because writing one is an encoder option.
func summaryDeclaration(_ source: ToolReader, _ walk: Walk) throws -> SummaryDeclaration? {
    // A whole Footer only. A file cut inside its own Footer has a record whose declared length is
    // the fault and whose content is not there, and reading a summary declaration out of it would
    // answer a question about the file with bytes the file does not have.
    guard let frame = walk.firstIntact(Opcode.footer) else { return nil }
    // `summary_start`, `summary_offset_start`, `summary_crc` — twenty bytes, and the only record
    // this tool reads the content of. A Footer a later revision extends still parses: the fields
    // this needs are the first three and they do not move.
    let fields: UInt64 = 20
    let content = frame.offset + recordHeaderSize
    guard frame.length >= fields else { return nil }
    let bytes = try source.exactly(offset: content, count: Int(fields), record: "Footer")
    guard let start = readU64(bytes, at: 0), let crc = readU32(bytes, at: 16) else { return nil }
    guard crc != 0, start != 0 else { return nil }
    // The summary ends where the Footer begins — taken from the walk rather than computed from a
    // footer's expected size, so a Footer that a later revision extends does not move the region
    // out from under the check.
    return SummaryDeclaration(start: start, crc: crc, end: frame.offset)
}

/// The in-memory convenience used by focused parser tests.
public func summaryDeclaration(_ bytes: [UInt8], _ walk: Walk) -> SummaryDeclaration? {
    try? summaryDeclaration(ToolReader(InMemoryReader(bytes)), walk)
}

/// The region the Footer's summary checksum covers, and whether it agrees.
///
/// The only checksum the format defines is `summary_crc` over the bytes from `summary_start` to
/// where the Footer begins. So a record's "CRC status" is a fact about the region it sits in
/// rather than a field of its own, and saying so per record is what tells a reader whether the
/// checksum has anything to say about the record they are looking at.
public struct Coverage {
    public let start: UInt64
    /// One past the last covered byte: where the Footer record's opcode sits.
    public let end: UInt64
    public let ok: Bool

    /// The cell for one record: `ok`, `MISMATCH`, or `-` for a record the checksum does not cover.
    public static func cell(_ coverage: Coverage?, at: UInt64, total: UInt64) -> String {
        guard let coverage else { return "-" }
        let (end, overflow) = at.addingReportingOverflow(total)
        guard !overflow, at >= coverage.start, end <= coverage.end else { return "-" }
        return coverage.ok ? "ok" : "MISMATCH"
    }
}

/// Empty when the file declares no summary checksum, which is a property of the file rather than
/// a failure: writing one is an encoder option.
func coverage(_ source: ToolReader, _ walk: Walk) throws -> Coverage? {
    guard let declared = try summaryDeclaration(source, walk), declared.start <= declared.end,
        declared.end <= walk.size
    else { return nil }

    // One fixed-size buffer at a time. `ByteRangeReader` returns owned bytes, so the storage is
    // replaced on every iteration instead of accumulating the checksum region.
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

/// The in-memory convenience used by focused checksum tests.
public func coverage(_ bytes: [UInt8], _ walk: Walk) -> Coverage? {
    try? coverage(ToolReader(InMemoryReader(bytes)), walk)
}

/// A refusal raised while decoding chunks, with the chunk it came from.
public struct ChunkRefusal {
    public let error: FourDGSError
    public let site: Site?
}

/// The first chunk that refuses, decoded one chunk at a time.
///
/// `nil` means every chunk decoded, which is the only evidence there is that a file's streams are
/// readable — the framing walk cannot produce it, because stepping over a chunk by its declared
/// length is exactly not looking inside it.
///
/// **One chunk resident at a time on the indexed path** (cross-SDK principle 1), which is what
/// keeps this bounded on a file too large to hold: each decoded chunk is dropped before the next
/// is read, because the question is whether every chunk decodes rather than what any of them
/// decoded to.
///
/// **Every band the file declares**, not band 0. Spherical harmonics do not enter reconstructed
/// state, so a *renderer* is right to cap them — but an SH Band Stream is a stream like any
/// other, and a band record carrying a codec this build does not implement is a file that does
/// not decode. Capping the bands here would report it `valid`.
func scanChunks(_ reader: SceneReader, index: [IndexEntry]) -> ChunkRefusal? {
    let chunks = reader.scene.chunkIntervals.count
    guard chunks > 0, reader.scene.isIndexed else {
        // The ABI cannot ask a non-indexed scene for one chunk. `validatePhysicalRecords` has
        // already exposed each physical Chunk to a one-chunk streamed reader, so there is nothing
        // to repeat here and no reason to call the unbounded whole-scene convenience.
        return nil
    }
    for i in 0..<chunks {
        do {
            // The decoded chunk is dropped here, at the end of the iteration.
            _ = try reader.chunk(i)
        } catch {
            return ChunkRefusal(error: asFourDGS(error), site: refusingRecord(reader, i, index))
        }
    }
    return nil
}

/// Which of a chunk's records the refusal came out of: the Chunk itself, or one band.
///
/// A chunk is not one record. The Chunk record carries the attribute streams and each
/// spherical-harmonic band sits in an SH Band Stream record of its own, somewhere else in the
/// file entirely — so "the chunk did not decode" can be about a byte thousands of bytes from
/// where the Chunk record starts, and pointing at the Chunk would send its reader to a stream
/// that is perfectly healthy.
///
/// ``FourDGS/SceneReader/chunk(_:options:)`` fetches the chunk and every band the cap admits in
/// one call, which is what a reader wants. Raising the cap until it starts failing is therefore
/// how to tell the two apart without restating the core's fetch here and drifting from it. It
/// costs a second decode of one chunk, and it only ever runs on the file that has already
/// refused. The band's own offset is the one the file's index declares, so this names the record
/// the reader was actually fetching rather than one inferred from record order.
private func refusingRecord(_ reader: SceneReader, _ i: Int, _ index: [IndexEntry]) -> Site? {
    guard i < index.count else { return nil }
    let entry = index[i]
    let chunk = Site(offset: entry.offset, what: "the Chunk record at index entry \(i)")
    guard (try? reader.chunk(i, options: DecodeOptions(bandCap: 0))) != nil else { return chunk }
    for band in entry.bands.sorted(by: { $0.band < $1.band }) {
        // The cap admits every band up to this one, and everything below it has already decoded,
        // so the first cap that fails names the band that failed.
        if (try? reader.chunk(i, options: DecodeOptions(bandCap: Int(band.band)))) == nil {
            return Site(
                offset: band.offset,
                what:
                    "the SH Band Stream for band \(band.band) of the Chunk at index entry \(i)")
        }
    }
    return chunk
}

/// What a refusal is told in, in the sentence whoever diagnosed it wrote.
///
/// Usually the error's own description, which names the byte, the record, the value found and the
/// value expected. The exception is an error the seam built out of a C ABI status: the core
/// reports those with a message and nothing else, so `CoreSeam` fills the case's remaining fields
/// with placeholders — an `offset: 0` that is not where anything went wrong, and whichever record
/// name the case's shape needed. Printing those beside a refusal whose whole point is the byte
/// would put two bytes on the screen, one of them wrong. So a wrapped message is printed as the
/// core wrote it, and every error the binding raised itself keeps its full description.
public func sentence(_ error: FourDGSError) -> String {
    switch error {
    case .unsupportedCodec(0, "Chunk", let message, _): return message
    case .malformed(0, "file", "", let reason, _): return reason
    case .truncated(0, let message, 0, 0): return message
    case .core(_, let message, _): return message
    default: return "\(error)"
    }
}

/// Anything thrown, as the SDK's error type.
///
/// Everything the package throws is already a ``FourDGS/FourDGSError``; the fallback exists
/// because `throws` is untyped in Swift 5.9 and a tool that crashed on the impossible case would
/// be worse than one that reports it as a transport failure with no refusal identifier.
public func asFourDGS(_ error: Error) -> FourDGSError {
    (error as? FourDGSError) ?? .unreadableSource(description: "\(error)")
}
