// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Authoring a `keyframe-delta` file: a sequence of populations in, bytes out.
///
/// ``SceneWriter`` authors the other temporal model — one population whose gaussians each
/// carry their own birth time. It cannot say the thing this model is for: the *same*
/// population, with identity, restated at a sequence of instants, with gaussians entering and
/// leaving (spec §11). So this is a separate writer rather than an option on that one, for
/// the same reason a Delta Chunk is its own record and not a flag on Chunk (spec §5.18).
///
/// Like ``SceneWriter``, this is a binding and not a second encoder: the sequence crosses into
/// the Rust core through ``CoreSeam`` and the bytes it returns are the bytes the reference
/// encoder writes for the same input. That is not merely convenient. A delta is a **difference
/// of bins, never a quantization of a difference** (spec §11.7) — which is what makes chained
/// deltas accumulate no error at any depth — and it holds only if every sample was quantized
/// up front on one set of grids derived from the whole sequence. An encoder that subtracted in
/// Swift and quantized afterwards would produce a file whose declared bounds mean nothing
/// after the second delta.

/// Which chunk a delta is stated against (spec §11.4).
public enum DeltaMode: UInt8, Sendable, Equatable {
    /// The reference is the keyframe at the head of the group. Always two records to
    /// reconstruct, however deep into the group the delta falls — the shape to place at a
    /// likely seek target such as a chapter boundary or a loop start.
    case keyframeReferenced = 0
    /// The reference is the state chunk immediately before this one. Smaller, and contiguous
    /// in the file so a range reader coalesces a chain into one request. The recommended
    /// default: chaining costs nothing in error here, so the choice is about cost alone.
    case chained = 1
}

/// One population, at one instant, with identity.
public struct KeyframeDeltaSample: Sendable, Equatable {
    /// When this state was stated. It is also the start of the interval the sample covers:
    /// sample `i` is valid over `[t0_i, t0_{i+1})`, and the last one runs to the duration.
    public var t0: Double
    /// One `gaussian_id` per gaussian, aligned with ``gaussians`` (spec §11.2).
    ///
    /// Required rather than derived from row order, because the whole model rests on
    /// correspondence between samples and a correspondence invented from row order is one the
    /// caller never asserted. Ids need not be dense, ordered, or start at zero; an id MUST NOT
    /// be reused after the gaussian carrying it dies.
    public var ids: [UInt32]
    public var gaussians: GaussianState

    public init(t0: Double, ids: [UInt32], gaussians: GaussianState) {
        self.t0 = t0
        self.ids = ids
        self.gaussians = gaussians
    }
}

/// Cadence and mode. The defaults are the reference encoder's own.
public struct KeyframeDeltaWriteOptions: Sendable, Equatable {
    /// Samples per group of pictures. `1` writes every sample as a keyframe, which is legal
    /// and is the shape the registry's `frame-sequence` reservation describes; `0` disables
    /// the cadence, leaving sample 0 and ``keyframeAt`` as the only keyframes.
    public var keyframeEvery: UInt32 = 8
    /// Which chunk each delta references. Per-sequence here; the format allows it per chunk.
    public var deltaMode: DeltaMode = .chained
    /// Sample indices to force a keyframe at, beyond the cadence. A producer that knows where
    /// a cut is puts one here so that instant is a whole restatement however deep into a group
    /// it would otherwise have fallen.
    public var keyframeAt: [UInt32] = []
    /// The error bounds the whole sequence is quantized against, and the Header's `profile`:
    /// `"fine"`, `"default"` or `"coarse"`. Unlike ``WriteOptions/profile`` — a free-form
    /// promise separate from the bounds — these are one value under this model, because the
    /// grids every sample is quantized on come from it.
    public var profile: String = "default"
    /// The Header's marginal visibility threshold, with the meaning it has on the other
    /// writer: it sets the support constant the per-gaussian velocity grid is derived from.
    public var cutoff: Double = 0.05
    /// The Header's `library`. Empty leaves the core's own default in place, so a caller that
    /// does not set it carries the same string every other default-configured writer does.
    public var library: String = ""
    /// The stream codec applied to every chunk's block. `0` is deflate, the format's default.
    public var codec: UInt8 = 0
    /// The codec's level.
    public var compressionLevel: UInt32 = 6

    public init() {}
}

/// Encode a sequence of populations into `keyframe-delta` bytes.
public enum KeyframeDeltaWriter {

    /// Encode `samples` over a `durationSec`-long timeline into `.4dgs` bytes.
    ///
    /// The samples must tile the timeline (spec §11.1): they are given in time order, the
    /// first starts at 0, each one's interval ends where the next begins, and the last ends at
    /// `durationSec`. The encoder derives each `t1` from the next sample's `t0` rather than
    /// checking the endpoints, so a sequence that misses this produces a file the indexed read
    /// path refuses as `non-tiling-chunks` while the streamed path accepts it — check the
    /// timeline you hand it, or read the result back on both paths as the tests here do.
    ///
    /// Throws the same typed errors ``SceneWriter`` does when the input is rejected: an empty
    /// sequence, a sample whose ids and gaussians are different lengths, a non-finite
    /// `sigmaT`, or a gaussian whose `sigmaT` or validity window changes inside a group. That
    /// last one is refused rather than written because those values *derive the grid* a bin
    /// difference is taken on (spec §11.5) — a file carrying such a change decodes silently
    /// into a wrong velocity rather than into an error, so it is the encoder's job to catch.
    /// The fix is always available: emit a death and a birth, or a keyframe.
    ///
    /// Spherical harmonics are not carried; a file written here declares `sh_degree` 0.
    public static func encode(
        _ samples: [KeyframeDeltaSample], durationSec: Double,
        options: KeyframeDeltaWriteOptions = KeyframeDeltaWriteOptions()
    ) throws -> [UInt8] {
        try Core.encodeKeyframeDelta(samples, durationSec: durationSec, options: options)
    }
}
