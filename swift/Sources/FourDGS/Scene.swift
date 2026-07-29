// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// What a file says about itself: everything but the gaussians.
///
/// A `Scene` is small and complete — the front matter, the optional records, and the index
/// if the file has one. It is a value, so holding one costs nothing and keeps nothing open.
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
    /// Empty when the file declares no index (`Footer.summary_start == 0`). Such a file is
    /// valid and must be read sequentially.
    public var chunkIndex: [ChunkIndexEntry]
    /// Whether the Footer's CRC over the summary region matched. `nil` when no CRC was
    /// declared or none was checked — which is a different statement from `false`.
    public var summaryChecksumVerified: Bool?

    public init(
        header: Header, audio: Audio? = nil, camera: Camera? = nil, metadata: [MetadataRecord] = [],
        attachments: [Attachment] = [], statistics: Statistics? = nil, summaryOffsets: [SummaryOffset] = [],
        chunkIndex: [ChunkIndexEntry] = [], summaryChecksumVerified: Bool? = nil
    ) {
        self.header = header
        self.audio = audio
        self.camera = camera
        self.metadata = metadata
        self.attachments = attachments
        self.statistics = statistics
        self.summaryOffsets = summaryOffsets
        self.chunkIndex = chunkIndex
        self.summaryChecksumVerified = summaryChecksumVerified
    }

    /// §8's whole seek algorithm: every index entry whose `[t0, t1)` contains `t`.
    public func chunks(containing t: Double) -> [ChunkIndexEntry] {
        chunkIndex.filter { $0.contains(t) }
    }
}

/// One chunk's gaussians and the interval they belong to.
public struct DecodedChunk: Sendable, Equatable {
    public var t0: Double
    public var t1: Double
    /// Producer's hierarchy level. Informational only.
    public var level: UInt32
    public var gaussians: GaussianState

    public init(t0: Double, t1: Double, level: UInt32, gaussians: GaussianState) {
        self.t0 = t0
        self.t1 = t1
        self.level = level
        self.gaussians = gaussians
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
    /// Check the Footer's CRC over the summary region when opening an indexed read.
    public var verifySummaryChecksum: Bool

    public init(bandCap: Int? = nil, verifySummaryChecksum: Bool = true) {
        self.bandCap = bandCap
        self.verifySummaryChecksum = verifySummaryChecksum
    }
}

// MARK: - Reading

/// Front-to-back decode: works on a pipe, on a file with no index, and on a file that has
/// been cut short.
///
/// Chunks arrive one at a time and the reader holds one at a time. Nothing here buffers the
/// whole file, and there is no `readAll` for it to be built on.
public struct StreamedReader<Source: ByteRangeReader> {
    /// The front matter, read when the reader was opened.
    public let scene: Scene
    private var source: Source
    private var cursor: Int64

    /// Read the front matter, up to the first Chunk.
    public init(_ source: Source) throws {
        var source = source
        let opened = try Core.readFrontMatter(&source)
        self.source = source
        self.scene = opened.scene
        self.cursor = opened.cursor
    }

    /// The next chunk, or `nil` at the end of the gaussian data.
    ///
    /// On a truncated file this throws ``FourDGSError/truncated(offset:record:needed:available:)``
    /// naming the record that ran out, rather than returning a short chunk: the chunks
    /// already returned are complete and correct, and that is what recovery means here.
    public mutating func nextChunk(options: DecodeOptions = DecodeOptions()) throws -> DecodedChunk? {
        try Core.nextChunk(&source, cursor: &cursor, options: options)
    }
}

/// Indexed decode: read the Footer, read the index, then touch only the byte ranges an
/// instant needs.
///
/// Not an optimization of ``StreamedReader`` — a different consumer with a different access
/// pattern. Both are first class.
public struct IndexedReader<Source: ByteRangeReader> {
    /// The front matter and the index, read when the reader was opened.
    public let scene: Scene
    private var source: Source

    /// Read the Footer, the index, and the front matter records the index points at.
    ///
    /// Throws ``FourDGSError/noChunkIndex`` if the file declares no index. That file is
    /// valid; it just has to be read with ``StreamedReader``.
    public init(_ source: Source, options: DecodeOptions = DecodeOptions()) throws {
        var source = source
        self.scene = try Core.readSummary(&source, options: options)
        self.source = source
    }

    /// Decode one indexed chunk, transferring only its bytes — and, under a band cap, only
    /// the bands at or below it.
    public mutating func chunk(
        _ entry: ChunkIndexEntry, options: DecodeOptions = DecodeOptions()
    ) throws
        -> DecodedChunk
    {
        try Core.decodeChunk(&source, entry: entry, options: options)
    }

    /// The gaussians live at scene time `t`, from the chunks whose intervals contain it.
    ///
    /// "Live" is §3's rule in full: inside the validity window, and marginal at or above
    /// the file's own cutoff. Positions are the rest positions as decoded — call
    /// ``Gaussian/state(at:)`` for a gaussian moved and faded to `t`.
    public mutating func gaussians(
        at t: Double, options: DecodeOptions = DecodeOptions()
    ) throws
        -> GaussianState
    {
        var decoded: [DecodedChunk] = []
        for entry in scene.chunks(containing: t) {
            decoded.append(try chunk(entry, options: options))
        }
        return GaussianState.live(in: decoded, at: t, cutoff: scene.header.cutoff)
    }
}
