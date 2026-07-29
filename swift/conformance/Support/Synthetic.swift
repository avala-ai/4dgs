// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import FourDGS

/// A scene built from a fixed seed, so that the Swift canonical emitter can be diffed
/// against `tests/conformance/canonical.py` before there is a decoder to produce one.
///
/// Without this, the first time the two emitters meet is the first time the ABI works, and
/// a disagreement then is ambiguous: the decode could be wrong, or the JSON could be. This
/// separates the questions. `selftest.py` builds the same scene from the same seed and runs
/// it through `canonical.py`; CI asserts the two documents parse equal.
///
/// The generator is the load-bearing part. Every value is computed in `Double` and narrowed
/// to `Float` exactly once, because `Double` arithmetic is bit-identical between Swift and
/// NumPy and a single round-to-nearest narrowing is too — whereas a chain of `Float`
/// operations is only identical if both sides happen to associate them the same way.
public enum Synthetic {

    /// The same constants as `numpy.random.PCG64`'s multiplier, used here as a plain LCG:
    /// the point is a sequence both languages reproduce exactly, not statistical quality.
    struct LCG {
        var state: UInt64

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }

        /// A `Double` in [0, 1) with 24 significant bits — exactly representable in both
        /// `Double` and `Float`, so no rounding happens here on either side.
        mutating func unit() -> Double {
            Double(next() >> 40) / 16_777_216.0
        }

        mutating func value(_ lo: Double, _ hi: Double) -> Float {
            Float(lo + unit() * (hi - lo))
        }
    }

    public static let gaussianCount = 300
    public static let shDegree = 2

    public static func scene() -> (Scene, GaussianState, [(Double, Double)]) {
        var rng = LCG(state: 0x4D47_5331_0D0A_0001)
        let n = gaussianCount
        let shWidth = ((shDegree + 1) * (shDegree + 1) - 1) * 3

        var positions = [Float]()
        var scales = [Float]()
        var rotations = [Float]()
        var colors = [Float]()
        var motions = [Float]()
        var muT = [Float]()
        var sigmaT = [Float]()
        var winLo = [Float]()
        var winHi = [Float]()
        var sh = [UInt8]()

        for i in 0..<n {
            for _ in 0..<3 { positions.append(rng.value(-10, 10)) }
            for _ in 0..<3 { scales.append(rng.value(0.001, 0.5)) }
            for _ in 0..<4 { rotations.append(rng.value(-1, 1)) }
            for _ in 0..<4 { colors.append(rng.value(0, 1)) }
            // Every fifth gaussian is motionless, so `zeroMotionCount` is a number both
            // sides have to agree on rather than always 0.
            if i % 5 == 0 {
                motions.append(contentsOf: [0, 0, 0])
            } else {
                for _ in 0..<3 { motions.append(rng.value(-2, 2)) }
            }
            muT.append(rng.value(0, 4))
            // Every third gaussian never fades, which is the `null` path through `num()`
            // and the `+inf` path through the sort key. Both are easy to get wrong and
            // invisible in a corpus that has neither.
            sigmaT.append(i % 3 == 0 ? .infinity : rng.value(0.001, 1.5))
            let lo = rng.value(0, 3)
            winLo.append(lo)
            winHi.append(Float(Double(lo) + 1.25))
            for _ in 0..<shWidth { sh.append(UInt8(rng.next() >> 56)) }
        }

        var gaussians = GaussianState(
            count: n, positions: positions, scales: scales, rotations: rotations, colors: colors,
            motions: motions, muT: muT, sigmaT: sigmaT, winLo: winLo, winHi: winHi, shDegree: shDegree,
            sh: sh)
        gaussians = tie(gaussians, 7, onto: 8)

        let scene = Scene(
            header: Header(
                profile: "", library: "4dgs synthetic", durationSec: 4.5, gaussianCount: UInt64(n),
                cutoff: 0.037, temporalModel: "gaussian-birth",
                aabb: [-10, -10, -10, 10, 10, 10], shDegree: shDegree, hasAudio: true,
                hasCompressedChunks: false,
                attributes: ["up_axis": "z", "visibility_profile": "gaussian", "note": "quote\" and \\ and \n"]),
            audio: Audio(codec: "opus", startSec: 0.25, data: (0..<5000).map { UInt8($0 % 251) }),
            camera: Camera(
                fovYDeg: 62.5, position: [1, 2, 3], target: [0, 0, 0],
                keyframes: (0..<6).map {
                    Camera.Keyframe(
                        time: Double($0) * 0.75, position: [Double($0), 1, 2], target: [0, Double($0), 0])
                },
                interpolation: "catmull-rom", loop: true),
            metadata: [
                MetadataRecord(name: "producer", entries: ["tool": "synthetic", "tab": "a\tb"]),
                MetadataRecord(name: "licence", entries: ["spdx": "CC-BY-4.0"]),
            ],
            attachments: [
                Attachment(name: "thumb.png", mediaType: "image/png", data: (0..<777).map { UInt8($0 % 256) }),
                Attachment(name: "notes.txt", mediaType: "text/plain", data: Array("hello".utf8)),
            ],
            statistics: Statistics(
                gaussianCount: UInt64(n), chunkCount: 3, durationSec: 4.5,
                aabb: [-10, -10, -10, 10, 10, 10]),
            summaryOffsets: [
                SummaryOffset(groupOpcode: 0x08, groupStart: 1024, groupLength: 256),
                SummaryOffset(groupOpcode: 0x0C, groupStart: 1280, groupLength: 48),
                SummaryOffset(groupOpcode: 0x0F, groupStart: 1328, groupLength: 60),
            ],
            summaryChecksumVerified: true)

        return (scene, gaussians, [(0, 1.5), (1.5, 3.0), (3.0, 4.5)])
    }

    /// Make one gaussian an exact duplicate of another.
    ///
    /// The content order has to break ties the same way in both languages, and a corpus
    /// with no ties never asks it to. Two gaussians identical in every decoded value are
    /// identical in every number the summary emits, so this cannot change the output — and
    /// that is the property being tested.
    static func tie(_ g: GaussianState, _ source: Int, onto target: Int) -> GaussianState {
        func copy(_ array: [Float], _ width: Int) -> [Float] {
            var out = array
            for k in 0..<width { out[target * width + k] = array[source * width + k] }
            return out
        }
        var shCopy = g.sh
        let shWidth = g.shCoefficientsPerComponent * 3
        for k in 0..<shWidth { shCopy[target * shWidth + k] = g.sh[source * shWidth + k] }
        return GaussianState(
            count: g.count, positions: copy(g.positions, 3), scales: copy(g.scales, 3),
            rotations: copy(g.rotations, 4), colors: copy(g.colors, 4), motions: copy(g.motions, 3),
            muT: copy(g.muT, 1), sigmaT: copy(g.sigmaT, 1), winLo: copy(g.winLo, 1),
            winHi: copy(g.winHi, 1), shDegree: g.shDegree, sh: shCopy)
    }
}
