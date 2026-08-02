// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// What a file says about itself: everything but the gaussians.
///
/// A `Scene` is a value, so holding one costs nothing and keeps nothing open. The reader it
/// came from owns the file.
///
/// Every field is read from the file. An empty `metadata` means the file carries none —
/// ``recordsAvailable`` is the flag that used to distinguish that from "this build cannot
/// ask", and it is now always `true` for a scene this package opened.
public struct Scene: Sendable, Equatable {
    public var header: Header
    /// Independently timed spatial or non-spatial descriptors, sorted by source id.
    ///
    /// Their `data` arrays are empty on open; `dataSize` describes the resource and
    /// `SceneReader.audioSourceData` performs bounded payload reads.
    public var audioSources: [AudioSource]
    public var camera: Camera?
    public var metadata: [MetadataRecord]
    public var attachments: [Attachment]
    public var statistics: Statistics?
    public var summaryOffsets: [SummaryOffset]
    /// The `[t0, t1)` interval of each chunk the index declares. Empty for a file with no
    /// index, which is valid and must be read sequentially.
    public var chunkIntervals: [ClosedRange<Double>]
    /// Whether the core opened this file on the indexed path.
    public var isIndexed: Bool
    /// Whether the file was cut short. What was read before the cut is still valid; this
    /// says the file ended before the rest of it.
    public var isTruncated: Bool
    /// Whether the Footer's CRC over the summary region matched. `nil` when no CRC was
    /// declared or none was checked — a different statement from `false`.
    public var summaryChecksumVerified: Bool?

    /// Whether the non-gaussian records above could be read at all.
    ///
    /// `false` would mean an empty `metadata` is silence rather than a statement — that
    /// nobody looked, not that the file carries none. It is `true` for every scene this
    /// package opens now that the ABI can reach those records; it stays in the API because
    /// the distinction is real and a future build could lose the ability again.
    public var recordsAvailable: Bool

    public init(
        header: Header, audioSources: [AudioSource] = [], camera: Camera? = nil,
        metadata: [MetadataRecord] = [],
        attachments: [Attachment] = [], statistics: Statistics? = nil, summaryOffsets: [SummaryOffset] = [],
        chunkIntervals: [ClosedRange<Double>] = [], isIndexed: Bool = false, isTruncated: Bool = false,
        summaryChecksumVerified: Bool? = nil, recordsAvailable: Bool = false
    ) {
        self.header = header
        self.audioSources = audioSources
        self.camera = camera
        self.metadata = metadata
        self.attachments = attachments
        self.statistics = statistics
        self.summaryOffsets = summaryOffsets
        self.chunkIntervals = chunkIntervals
        self.isIndexed = isIndexed
        self.isTruncated = isTruncated
        self.summaryChecksumVerified = summaryChecksumVerified
        self.recordsAvailable = recordsAvailable
    }

    /// §8's whole seek algorithm: every chunk whose `[t0, t1)` contains `t`.
    public func chunks(containing t: Double) -> [Int] {
        chunkIntervals.indices.filter {
            t >= chunkIntervals[$0].lowerBound && t < chunkIntervals[$0].upperBound
        }
    }
}

/// How much of a chunk to decode.
public struct DecodeOptions: Sendable, Equatable {
    /// Evaluate only spherical-harmonic bands at or below this one. `nil` means every band
    /// the file carries.
    ///
    /// On an indexed read this is a transport decision, not a filter: each band has its own
    /// byte range in the index, so the bands above the cap are never transferred. Bands are
    /// whole — a reader must not assemble a partial degree out of part of a band.
    public var bandCap: Int?

    public init(bandCap: Int? = nil) {
        self.bandCap = bandCap
    }
}

// MARK: - Reading

/// An open `.4dgs` file.
///
/// A `final class` rather than a struct, deliberately: it owns a handle from across an FFI
/// boundary, and a struct would be copied by every assignment and freed once per copy. One
/// owner, freed once, in `deinit`.
///
/// A reader is **not** `Sendable` — one open scene belongs to one thread at a time, which
/// is what the core promises. What comes *out* of it is `Sendable`, because every array is
/// copied out of the core's memory before it is returned, so decoded state can cross an
/// actor boundary freely. That asymmetry is the useful one: decode on a worker, hand the
/// result anywhere.
public final class SceneReader {

    /// What the file says about itself, read when the reader was opened.
    public let scene: Scene

    private let handle: Core.SceneHandle

    /// Which path to read the file by.
    ///
    /// Streamed and indexed are two consumers, not two speeds: streaming works on a pipe
    /// and on a file with no index, and an indexed read touches only what an instant needs.
    /// Neither is an optimization of the other, and the conformance suite runs one runner
    /// for each so that they are able to disagree.
    public enum ReadPath {
        /// Let the core choose: indexed when the file has an index, sequential otherwise.
        case automatic
        /// Front to back, no seeking. Works on a file with no index and on a truncated one.
        case streamed
        /// Footer, then index, then only the byte ranges asked for.
        case indexed

        var mode: Core.OpenMode {
            switch self {
            case .automatic: return .auto
            case .streamed: return .sequential
            case .indexed: return .indexed
            }
        }
    }

    /// Open a scene over any byte-range reader.
    ///
    /// The reader is retained for the scene's whole life and released exactly once when
    /// this object is deallocated.
    public init(_ source: any ByteRangeReader, path readPath: ReadPath = .automatic) throws {
        var probe = source
        // Eight bytes and one comparison, before anything untrusted crosses into code that
        // cannot throw. The core checks the magic too; a binding checking what it cheaply
        // can at the boundary is the job, not duplication for its own sake.
        try Core.validateMagic(&probe)

        let handle = try Core.open(source, mode: readPath.mode)
        self.handle = handle
        try Core.loadRecords(handle)
        self.scene = Scene(
            header: try Core.header(handle),
            audioSources: try Core.audioSources(handle),
            camera: try Core.camera(handle),
            metadata: try Core.metadata(handle),
            attachments: try Core.attachments(handle),
            statistics: try Core.statistics(handle),
            summaryOffsets: try Core.summaryOffsets(handle),
            chunkIntervals: try Core.chunkIntervals(handle).map { $0.0...$0.1 },
            isIndexed: Core.isIndexed(handle),
            isTruncated: Core.isTruncated(handle),
            summaryChecksumVerified: Core.summaryChecksum(handle),
            recordsAvailable: true)
    }

    /// Open a file on disk.
    public convenience init(path: String, readPath: ReadPath = .automatic) throws {
        try self.init(FileReader(path: path), path: readPath)
    }

    /// Decode chunk `i` on its own, transferring only its byte ranges.
    public func chunk(_ i: Int, options: DecodeOptions = DecodeOptions()) throws -> GaussianState {
        try Core.loadChunk(handle, UInt32(i), bandCap: options.bandCap)
    }

    /// What reading chunk `i` would transfer at this band cap — measured at the transport,
    /// which is what makes "never fetch a band you will not evaluate" a checkable claim
    /// rather than an intention.
    public func bytesForChunk(_ i: Int, options: DecodeOptions = DecodeOptions()) -> UInt64 {
        Core.bytesForChunk(handle, UInt32(i), bandCap: options.bandCap)
    }

    /// Every gaussian in the file, decoded.
    ///
    /// Bounded memory is a property of the decoder, not of this call: the core walks chunk
    /// by chunk. This returns the whole working set because the caller asked for it.
    public func allGaussians(options: DecodeOptions = DecodeOptions()) throws -> GaussianState {
        try Core.loadAll(handle, bandCap: options.bandCap)
    }

    /// Every gaussian in the chunks that scene time `t` touches, decoded but not yet
    /// filtered — the working set for that instant.
    ///
    /// Transfers only those chunks' byte ranges, and under a band cap only the bands at or
    /// below it.
    public func loadedGaussians(
        at t: Double, options: DecodeOptions = DecodeOptions()
    ) throws
        -> GaussianState
    {
        try Core.load(handle, at: t, bandCap: options.bandCap)
    }

    /// The gaussians that exist at scene time `t`.
    ///
    /// §3's rule in full: inside the half-open validity window, and marginal at or above
    /// **this file's** cutoff. Positions come back as decoded rest positions; call
    /// ``Gaussian/state(at:)`` for one moved and faded to `t`.
    public func gaussians(
        at t: Double, options: DecodeOptions = DecodeOptions()
    ) throws
        -> GaussianState
    {
        try loadedGaussians(at: t, options: options).live(at: t, cutoff: scene.header.cutoff)
    }

    /// The scene reconstructed at `t`: what is visible, where it is, and how opaque.
    ///
    /// Prefer this over reconstructing from ``gaussians(at:options:)`` by hand when the file
    /// carries an object layer. ``Gaussian/state(at:)`` is §3 and nothing more — it moves a
    /// gaussian along its own velocity and fades it — while this composes any Object Track
    /// (spec §5.15.7) onto the base centre and orientation, in the core, so every binding
    /// shares one base-then-track order. For a scene with tracks the two disagree, and this
    /// is the one that matches what the file describes.
    public func stateAt(
        _ t: Double, options: DecodeOptions = DecodeOptions()
    ) throws
        -> InstantState
    {
        try Core.stateAt(handle, t, bandCap: options.bandCap)
    }

    /// A conservative upper bound on a cold seek to `t`, so a consumer can budget before
    /// asking for it. It includes every Object Track the
    /// decoded memberships could reference; actual transfer may be lower after validation
    /// is cached.
    public func bytesForTime(_ t: Double, options: DecodeOptions = DecodeOptions()) -> UInt64 {
        Core.bytesForTime(handle, t, bandCap: options.bandCap)
    }

    /// Canonical provenance JSON (spec §5.15), computed in the Rust core so every binding
    /// emits the same object. Empty when the file carries none — omit the key rather than
    /// emit null. On the indexed path the records are fetched here if not already resident.
    public func provenanceJson() throws -> String {
        try Core.provenanceJson(handle)
    }

    /// The `objects` member of the canonical summary (spec §5.15.6-§5.15.7), or empty when
    /// the file carries neither object records nor per-gaussian membership.
    ///
    /// Computed by the core, like `provenanceJson`, so this binding and the C++ one cannot
    /// drift from Rust on composition order or pose interpolation.
    ///
    /// **This call loads.** The summary describes every gaussian, so the core decodes the
    /// whole population — at the file's full SH degree, because the canonical order keys
    /// the harmonics before `object_id` and a lower degree would sort a legal file
    /// differently from the reference. Any band cap is put back before this returns. A
    /// scene that had seeked to an instant holds the whole thing afterwards. Nothing
    /// dangles the way it can in C: ``GaussianState`` owns Swift storage copied out of the
    /// core, so a value taken earlier stays valid and stays what it was.
    public func objectsJson() throws -> String {
        try Core.objectsJson(handle)
    }

    /// The `states` member: composed centres, orientations and membership at each probe.
    /// Loads on the same terms as ``objectsJson()``.
    public func objectStatesJson() throws -> String {
        try Core.objectStatesJson(handle)
    }

    /// Read a bounded range of one source's encoded payload.
    public func audioSourceData(
        _ index: Int, offset: UInt64 = 0, length: UInt64
    ) throws -> [UInt8] {
        guard index >= 0, index < scene.audioSources.count else {
            throw FourDGSError.invalidRange(offset: Int64(index), count: 1)
        }
        let size = scene.audioSources[index].dataSize
        guard offset <= size, length <= size - offset else {
            throw FourDGSError.malformed(
                offset: 0, record: "Audio Data", field: "range",
                reason: "offset \(offset) plus length \(length) is outside the \(size)-byte payload")
        }
        return try Core.audioSourceData(handle, index: UInt32(index), offset: offset, length: length)
    }

    /// Reconstruct a source's active state, local playback time and moving pose.
    ///
    /// The player combines this scene-space state with its listener orientation and owns
    /// HRTF/panning, distance attenuation, occlusion and mixing.
    public func audioSourceState(_ index: Int, at t: Double) throws -> AudioSourceState {
        guard index >= 0, index < scene.audioSources.count else {
            throw FourDGSError.invalidRange(offset: Int64(index), count: 1)
        }
        return try Core.audioSourceState(handle, index: UInt32(index), at: t)
    }
}
