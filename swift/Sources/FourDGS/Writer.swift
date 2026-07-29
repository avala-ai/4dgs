// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Authoring a `.4dgs` file: gaussians in, bytes out.
///
/// The mirror of ``SceneReader``. Decoding ends at gaussian state; encoding begins there, and
/// what produced the gaussians — a fit, a conversion, a capture — is out of scope exactly as
/// drawing them is on the read side. This is a binding, not a second encoder: the one call
/// crosses into the Rust core through ``CoreSeam`` and no other file touches the ABI.

/// How a scene is written. The defaults are the encoder's own: a full summary with an index
/// and a CRC, all three spherical harmonic bands, and no per-band bit depths.
public struct WriteOptions: Sendable, Equatable {
    /// The Header's marginal visibility threshold. It sets the support constant the
    /// per-gaussian velocity grid is derived from, so it must be the one a decoder reads back.
    public var cutoff: Double = 0.05
    /// The temporal partition's depth. `0` writes one chunk per window.
    public var maxDepth: UInt32 = 6
    /// A node with fewer gaussians than this gives them back to its parent rather than
    /// becoming a chunk of its own.
    public var minChunkGaussians: Int = 2048
    public var writeIndex: Bool = true
    public var writeStatistics: Bool = false
    public var writeSummaryOffsets: Bool = false
    public var writeCrc: Bool = true
    /// The highest spherical harmonic band to write, `0` to `3`.
    public var shBands: UInt8 = 3
    /// Per-band bit depths, band 1 first. Empty leaves the coefficients as the profile alone
    /// decides — what a file written before this option existed did, byte for byte.
    public var shBitDepths: [UInt8] = []
    /// The Header's `profile`: a promise about the file's shape.
    public var profile: String = ""
    /// The Header's `library`. Empty leaves the encoder's own default in place, so a caller
    /// that does not set it carries the same string every other default-configured writer does.
    public var library: String = ""
    /// The Header's free-form attributes map.
    public var attributes: [String: String] = [:]

    public init() {}
}

/// Encode decoded gaussians into a `.4dgs` byte buffer.
public enum SceneWriter {

    /// Encode `gaussians` over a `durationSec`-long timeline into `.4dgs` bytes.
    ///
    /// The encoder verifies its own bounds before returning — it decodes every chunk back and
    /// refuses a file whose measured deviation exceeds what it declares — so a success is a
    /// file whose Quantization record was checked on every gaussian. Throws the same typed
    /// errors ``SceneReader`` does when the input is rejected.
    public static func encode(
        _ gaussians: GaussianState, durationSec: Double, options: WriteOptions = WriteOptions()
    ) throws -> [UInt8] {
        try Core.encode(gaussians, durationSec: durationSec, options: options)
    }
}
