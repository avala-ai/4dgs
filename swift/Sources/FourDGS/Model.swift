// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The records a `.4dgs` file describes, as Swift values.
///
/// Every type here is a `struct` and every one is `Sendable`: a decoded scene is data, it
/// can cross an actor boundary, and nothing in it refers back to the reader it came from.
/// The names are the ones in `website/docs/guides/concepts.md`, cased the way Swift cases
/// things — one vocabulary, spelled in the local language.

public typealias Vector3 = SIMD3<Float>
/// A unit quaternion in xyzw order, matching the wire layout.
public typealias Quaternion = SIMD4<Float>

// MARK: - Header

/// Everything a reader knows before it touches a chunk. §5.1.
public struct Header: Sendable, Equatable {
    /// A well-known profile name, or `""` for the base format with no extra promises.
    public var profile: String
    /// Free-form producer identification.
    public var library: String
    /// Scene length; playback covers `[0, durationSec)`.
    public var durationSec: Double
    /// Total gaussians across all chunks.
    public var gaussianCount: UInt64
    /// Marginal visibility threshold; the file's own value, not the 0.05 default.
    public var cutoff: Double
    /// `"gaussian-birth"` for version 1.
    public var temporalModel: String
    /// Min xyz then max xyz over all rest positions.
    public var aabb: [Double]
    /// 0...3; 0 means no spherical harmonics.
    public var shDegree: Int
    /// `true` when the file carries any audio representation. §7's discovery rule answers
    /// this from the Header alone, with no further reads.
    public var hasAudio: Bool
    /// `true` when chunk data is compressed.
    public var hasCompressedChunks: Bool
    /// Free-form; the registry lists the well-known keys.
    public var attributes: [String: String]

    public init(
        profile: String, library: String, durationSec: Double, gaussianCount: UInt64, cutoff: Double,
        temporalModel: String, aabb: [Double], shDegree: Int, hasAudio: Bool, hasCompressedChunks: Bool,
        attributes: [String: String]
    ) {
        self.profile = profile
        self.library = library
        self.durationSec = durationSec
        self.gaussianCount = gaussianCount
        self.cutoff = cutoff
        self.temporalModel = temporalModel
        self.aabb = aabb
        self.shDegree = shDegree
        self.hasAudio = hasAudio
        self.hasCompressedChunks = hasCompressedChunks
        self.attributes = attributes
    }
}

// MARK: - Optional records

/// Legacy non-spatial audio result, retained for source compatibility.
public struct Audio: Sendable, Equatable {
    /// A well-known audio codec name from the registry.
    public var codec: String
    /// Scene time at which the track's first sample plays.
    public var startSec: Double
    /// The encoded track, verbatim.
    public var data: [UInt8]

    public init(codec: String, startSec: Double, data: [UInt8]) {
        self.codec = codec
        self.startSec = startSec
        self.data = data
    }
}

/// One independently timed encoded payload and its scene-space pose.
public struct AudioSource: Sendable, Equatable {
    public struct Keyframe: Sendable, Equatable {
        public var time: Double
        public var position: [Double]
        /// Unit quaternion in xyzw order.
        public var rotation: [Double]

        public init(time: Double, position: [Double], rotation: [Double]) {
            self.time = time
            self.position = position
            self.rotation = rotation
        }
    }

    public var sourceId: UInt32
    public var name: String
    public var codec: String
    public var channelLayout: String
    public var startSec: Double
    public var durationSec: Double
    public var gain: Double
    public var spatial: Bool
    public var loop: Bool
    public var position: [Double]
    /// Unit quaternion in xyzw order.
    public var rotation: [Double]
    public var keyframes: [Keyframe]
    public var interpolation: String
    /// Encoded payload length. The bytes are fetched separately on indexed paths.
    public var dataSize: UInt64
    public var data: [UInt8]

    public init(
        sourceId: UInt32, name: String = "", codec: String, channelLayout: String = "mono",
        startSec: Double = 0, durationSec: Double, gain: Double = 1, spatial: Bool = true,
        loop: Bool = false, position: [Double] = [0, 0, 0],
        rotation: [Double] = [0, 0, 0, 1], keyframes: [Keyframe] = [],
        interpolation: String = "linear", dataSize: UInt64? = nil, data: [UInt8] = []
    ) {
        self.sourceId = sourceId
        self.name = name
        self.codec = codec
        self.channelLayout = channelLayout
        self.startSec = startSec
        self.durationSec = durationSec
        self.gain = gain
        self.spatial = spatial
        self.loop = loop
        self.position = position
        self.rotation = rotation
        self.keyframes = keyframes
        self.interpolation = interpolation
        self.dataSize = dataSize ?? UInt64(data.count)
        self.data = data
    }
}

/// Format reconstruction at one scene time. Listener-relative spatialization is
/// deliberately player-owned.
public struct AudioSourceState: Sendable, Equatable {
    public var active: Bool
    public var localTime: Double
    public var position: [Double]
    public var rotation: [Double]
    public var gain: Double

    public init(
        active: Bool, localTime: Double, position: [Double], rotation: [Double], gain: Double
    ) {
        self.active = active
        self.localTime = localTime
        self.position = position
        self.rotation = rotation
        self.gain = gain
    }
}

extension AudioSource {
    /// Reconstruct timing and moving pose. Listener-relative playback stays in the player.
    public func state(at t: Double) -> AudioSourceState {
        let active = t >= startSec && (loop || t < startSec + durationSec)
        let localTime =
            loop && durationSec > 0
            ? loopingLocalTime(t, startSec, durationSec)
            : min(max(0, t - startSec), max(0, durationSec))

        let pose: ([Double], [Double])
        if keyframes.isEmpty {
            pose = (position, normalizedQuaternion(rotation))
        } else if t <= keyframes[0].time {
            pose = (keyframes[0].position, normalizedQuaternion(keyframes[0].rotation))
        } else if t >= keyframes[keyframes.count - 1].time {
            let last = keyframes[keyframes.count - 1]
            pose = (last.position, normalizedQuaternion(last.rotation))
        } else {
            let high = keyframes.firstIndex { $0.time > t }!
            let a = keyframes[high - 1]
            let b = keyframes[high]
            if interpolation == "step" {
                pose = (a.position, normalizedQuaternion(a.rotation))
            } else {
                let u = (t - a.time) / (b.time - a.time)
                pose = (
                    zip(a.position, b.position).map { pair in
                        pair.0 + (pair.1 - pair.0) * u
                    },
                    quaternionSlerp(a.rotation, b.rotation, u)
                )
            }
        }
        return AudioSourceState(
            active: active, localTime: localTime, position: pose.0, rotation: pose.1, gain: gain)
    }
}

private func loopingLocalTime(_ t: Double, _ startSec: Double, _ durationSec: Double) -> Double {
    if t <= startSec {
        return 0
    }
    var timeRemainder = t.truncatingRemainder(dividingBy: durationSec)
    if timeRemainder < 0 {
        timeRemainder += durationSec
    }
    var startRemainder = startSec.truncatingRemainder(dividingBy: durationSec)
    if startRemainder < 0 {
        startRemainder += durationSec
    }
    let difference = timeRemainder - startRemainder
    return difference < 0 ? difference + durationSec : difference
}

private func normalizedQuaternion(_ value: [Double]) -> [Double] {
    // Divide out the largest component before squaring so a finite but very large component
    // cannot overflow to `inf` — which would make the norm `inf`, trip the guard below, and
    // collapse a valid extreme orientation to the identity instead of the unit quaternion in
    // its own direction.
    let scale = value.map { abs($0) }.max() ?? 0
    guard scale.isFinite, scale > 0 else { return [0, 0, 0, 1] }
    let scaled = value.map { $0 / scale }
    let length = sqrt(scaled.reduce(0) { $0 + $1 * $1 })
    guard length.isFinite, length > 0 else { return [0, 0, 0, 1] }
    return scaled.map { $0 / length }
}

private func quaternionSlerp(_ a: [Double], _ b: [Double], _ u: Double) -> [Double] {
    let qa = normalizedQuaternion(a)
    var qb = normalizedQuaternion(b)
    var dot = zip(qa, qb).reduce(0) { $0 + $1.0 * $1.1 }
    if dot < 0 {
        qb = qb.map { -$0 }
        dot = -dot
    }
    dot = min(1, max(-1, dot))
    if dot > 0.9995 {
        return normalizedQuaternion(
            zip(qa, qb).map { pair in pair.0 + (pair.1 - pair.0) * u })
    }
    let theta = acos(dot)
    let sinTheta = sin(theta)
    let wa = sin((1 - u) * theta) / sinTheta
    let wb = sin(u * theta) / sinTheta
    return normalizedQuaternion(zip(qa, qb).map { pair in wa * pair.0 + wb * pair.1 })
}

/// A default viewpoint and optional suggested path. §5.10. Purely advisory.
public struct Camera: Sendable, Equatable {
    public struct Keyframe: Sendable, Equatable {
        public var time: Double
        public var position: [Double]
        public var target: [Double]

        public init(time: Double, position: [Double], target: [Double]) {
            self.time = time
            self.position = position
            self.target = target
        }
    }

    public var fovYDeg: Double
    public var position: [Double]
    public var target: [Double]
    public var keyframes: [Keyframe]
    public var interpolation: String
    public var loop: Bool

    public init(
        fovYDeg: Double, position: [Double], target: [Double], keyframes: [Keyframe], interpolation: String,
        loop: Bool
    ) {
        self.fovYDeg = fovYDeg
        self.position = position
        self.target = target
        self.keyframes = keyframes
        self.interpolation = interpolation
        self.loop = loop
    }
}

/// A named string map. §5.11.
public struct MetadataRecord: Sendable, Equatable {
    public var name: String
    public var entries: [String: String]

    public init(name: String, entries: [String: String]) {
        self.name = name
        self.entries = entries
    }
}

/// An arbitrary payload — a thumbnail, provenance, a licence. §5.13.
///
/// Attachments are not the mechanism for audio; audio has its own record because it is a
/// first-class part of the scene.
public struct Attachment: Sendable, Equatable {
    public var name: String
    public var mediaType: String
    public var data: [UInt8]

    public init(name: String, mediaType: String, data: [UInt8]) {
        self.name = name
        self.mediaType = mediaType
        self.data = data
    }
}

/// A summary a reader may trust without scanning chunks. §5.12. Advisory: a reader that
/// needs certainty computes from the chunks.
public struct Statistics: Sendable, Equatable {
    public var gaussianCount: UInt64
    public var chunkCount: UInt32
    public var durationSec: Double
    public var aabb: [Double]

    public init(gaussianCount: UInt64, chunkCount: UInt32, durationSec: Double, aabb: [Double]) {
        self.gaussianCount = gaussianCount
        self.chunkCount = chunkCount
        self.durationSec = durationSec
        self.aabb = aabb
    }
}

/// Where one class of index record starts and ends, so a reader can range-read it without
/// reading the others. §5.14.
public struct SummaryOffset: Sendable, Equatable {
    public var groupOpcode: UInt8
    public var groupStart: UInt64
    public var groupLength: UInt64

    public init(groupOpcode: UInt8, groupStart: UInt64, groupLength: UInt64) {
        self.groupOpcode = groupOpcode
        self.groupStart = groupStart
        self.groupLength = groupLength
    }
}

// MARK: - Gaussian state

/// Reconstructed gaussian state, structure-of-arrays.
///
/// Flat `[Float]` rather than an array of structs, deliberately: this is the shape a
/// renderer uploads and the shape a decoder can fill without per-gaussian allocation. Use
/// ``subscript(_:)`` when you want one gaussian as a value.
///
/// **Order is not part of the contract.** An encoder may reorder gaussians freely and a
/// reader must not rely on the order it gets.
public struct GaussianState: Sendable, Equatable {
    /// Number of gaussians. Every per-attribute array is this long times its width.
    public let count: Int
    /// Rest positions, 3 per gaussian.
    public let positions: [Float]
    /// Linear scales, 3 per gaussian.
    public let scales: [Float]
    /// Unit quaternions in xyzw order, 4 per gaussian.
    public let rotations: [Float]
    /// Linear RGB and opacity in [0, 1], 4 per gaussian.
    public let colors: [Float]
    /// Linear velocity in units per second, 3 per gaussian.
    public let motions: [Float]
    /// Temporal centre in seconds.
    public let muT: [Float]
    /// Temporal standard deviation in seconds; `.infinity` means the gaussian never fades.
    public let sigmaT: [Float]
    /// Validity window start, seconds.
    public let winLo: [Float]
    /// Validity window end, seconds. The window is half-open: `[winLo, winHi)`.
    public let winHi: [Float]
    /// 0...3. `0` means ``sh`` is empty.
    public let shDegree: Int
    /// Spherical-harmonic coefficients as stored: unsigned bytes, consumed as read.
    ///
    /// `(shDegree + 1)² − 1` coefficients per colour component per gaussian, laid out
    /// band by band and component-major within a band. `step_sh` from the Quantization
    /// record is an encode-side value and is **not** applied here — multiplying by it
    /// scales appearance by one to three and is the single most likely way to misread the
    /// record.
    public let sh: [UInt8]

    public init(
        count: Int, positions: [Float], scales: [Float], rotations: [Float], colors: [Float],
        motions: [Float],
        muT: [Float], sigmaT: [Float], winLo: [Float], winHi: [Float], shDegree: Int, sh: [UInt8]
    ) {
        self.count = count
        self.positions = positions
        self.scales = scales
        self.rotations = rotations
        self.colors = colors
        self.motions = motions
        self.muT = muT
        self.sigmaT = sigmaT
        self.winLo = winLo
        self.winHi = winHi
        self.shDegree = shDegree
        self.sh = sh
    }

    /// An empty state, which is what an interval with no live gaussians decodes to.
    public static let empty = GaussianState(
        count: 0, positions: [], scales: [], rotations: [], colors: [], motions: [], muT: [], sigmaT: [],
        winLo: [], winHi: [], shDegree: 0, sh: [])

    /// Spherical-harmonic coefficients per colour component, per gaussian.
    public var shCoefficientsPerComponent: Int {
        shDegree == 0 ? 0 : (shDegree + 1) * (shDegree + 1) - 1
    }

    /// One gaussian as a value. A view, not a copy of the arrays.
    public subscript(index: Int) -> Gaussian {
        precondition(index >= 0 && index < count, "gaussian index \(index) out of range 0..<\(count)")
        return Gaussian(
            position: Vector3(positions[index * 3], positions[index * 3 + 1], positions[index * 3 + 2]),
            scale: Vector3(scales[index * 3], scales[index * 3 + 1], scales[index * 3 + 2]),
            rotation: Quaternion(
                rotations[index * 4], rotations[index * 4 + 1], rotations[index * 4 + 2],
                rotations[index * 4 + 3]),
            color: SIMD4<Float>(
                colors[index * 4], colors[index * 4 + 1], colors[index * 4 + 2], colors[index * 4 + 3]),
            motion: Vector3(motions[index * 3], motions[index * 3 + 1], motions[index * 3 + 2]),
            muT: muT[index], sigmaT: sigmaT[index], winLo: winLo[index], winHi: winHi[index])
    }
}

/// One gaussian's decoded state, as a value.
public struct Gaussian: Sendable, Equatable {
    public var position: Vector3
    public var scale: Vector3
    /// Unit quaternion, xyzw.
    public var rotation: Quaternion
    /// Linear RGB in `xyz`, opacity in `w`.
    public var color: SIMD4<Float>
    public var motion: Vector3
    public var muT: Float
    /// `.infinity` means this gaussian never fades.
    public var sigmaT: Float
    public var winLo: Float
    public var winHi: Float

    public init(
        position: Vector3, scale: Vector3, rotation: Quaternion, color: SIMD4<Float>, motion: Vector3,
        muT: Float, sigmaT: Float, winLo: Float, winHi: Float
    ) {
        self.position = position
        self.scale = scale
        self.rotation = rotation
        self.color = color
        self.motion = motion
        self.muT = muT
        self.sigmaT = sigmaT
        self.winLo = winLo
        self.winHi = winHi
    }

    /// `true` when this gaussian has a marginal of 1 across its whole validity window:
    /// full opacity, hard edges, no fade. §3.1's `box` visibility profile.
    public var neverFades: Bool {
        sigmaT.isInfinite
    }
}
