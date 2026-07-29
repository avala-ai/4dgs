// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// What a file says about itself: everything but the gaussians.
///
/// A `Scene` is a value, so holding one costs nothing and keeps nothing open. The reader it
/// came from owns the file.
///
/// **Not every field is populated yet.** The C ABI reaches the Header's numbers, the audio
/// track and the chunk intervals; it has no accessor for the metadata, attachment, camera,
/// statistics or summary-offset records, so those stay empty here — not because the file
/// lacks them, but because this binding cannot yet ask. ``recordsAvailable`` says which of
/// the two it is, so nothing downstream mistakes "not readable yet" for "not present".
public struct Scene: Sendable, Equatable {
    public var header: Header
    /// `nil` when the scene has no audio, which is the common case and not an error. The
    /// Header's audio flag alone decides this; no probing and no speculative range read.
    public var audio: Audio?
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
    /// Whether the Footer's CRC over the summary region matched. `nil` when no CRC was
    /// declared or none was checked — a different statement from `false`.
    public var summaryChecksumVerified: Bool?

    /// Whether the non-gaussian records above could be read at all.
    ///
    /// `false` means this build of the binding has no way to reach them, so an empty
    /// `metadata` is silence rather than a statement. It exists because the alternative —
    /// an empty array that looks like a fact — is exactly how a consumer ends up believing
    /// a file carries no licence when nobody ever looked.
    public var recordsAvailable: Bool

    public init(
        header: Header, audio: Audio? = nil, camera: Camera? = nil, metadata: [MetadataRecord] = [],
        attachments: [Attachment] = [], statistics: Statistics? = nil, summaryOffsets: [SummaryOffset] = [],
        chunkIntervals: [ClosedRange<Double>] = [], isIndexed: Bool = false,
        summaryChecksumVerified: Bool? = nil, recordsAvailable: Bool = false
    ) {
        self.header = header
        self.audio = audio
        self.camera = camera
        self.metadata = metadata
        self.attachments = attachments
        self.statistics = statistics
        self.summaryOffsets = summaryOffsets
        self.chunkIntervals = chunkIntervals
        self.isIndexed = isIndexed
        self.summaryChecksumVerified = summaryChecksumVerified
        self.recordsAvailable = recordsAvailable
    }

    /// §8's whole seek algorithm: every chunk whose `[t0, t1)` contains `t`.
    public func chunks(containing t: Double) -> [Int] {
        chunkIntervals.indices.filter { t >= chunkIntervals[$0].lowerBound && t < chunkIntervals[$0].upperBound }
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

    /// Open a scene over any byte-range reader.
    ///
    /// The reader is retained for the scene's whole life and released exactly once when
    /// this object is deallocated.
    public init(_ source: any ByteRangeReader) throws {
        var probe = source
        // Eight bytes and one comparison, before anything untrusted crosses into code that
        // cannot throw. The core checks the magic too; a binding checking what it cheaply
        // can at the boundary is the job, not duplication for its own sake.
        try Core.validateMagic(&probe)

        let handle = try Core.open(source)
        self.handle = handle
        self.scene = Scene(
            header: Core.header(handle),
            audio: try Core.audio(handle),
            chunkIntervals: try Core.chunkIntervals(handle).map { $0.0...$0.1 },
            isIndexed: Core.isIndexed(handle),
            recordsAvailable: false)
    }

    /// Open a file on disk.
    public convenience init(path: String) throws {
        try self.init(FileReader(path: path))
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
    public func loadedGaussians(at t: Double, options: DecodeOptions = DecodeOptions()) throws
        -> GaussianState
    {
        try Core.load(handle, at: t, bandCap: options.bandCap)
    }

    /// The gaussians that exist at scene time `t`.
    ///
    /// §3's rule in full: inside the half-open validity window, and marginal at or above
    /// **this file's** cutoff. Positions come back as decoded rest positions; call
    /// ``Gaussian/state(at:)`` for one moved and faded to `t`.
    public func gaussians(at t: Double, options: DecodeOptions = DecodeOptions()) throws
        -> GaussianState
    {
        try loadedGaussians(at: t, options: options).live(at: t, cutoff: scene.header.cutoff)
    }

    /// What a seek to `t` would transfer, so a consumer can budget before asking for it.
    ///
    /// Seek cost is a property of the content, not of the container: a scene whose
    /// gaussians all live for the whole clip has one chunk covering everything, and this
    /// will say so rather than let anyone discover it by fetching the file.
    public func bytesForTime(_ t: Double, options: DecodeOptions = DecodeOptions()) -> UInt64 {
        Core.bytesForTime(handle, t, bandCap: options.bandCap)
    }
}
