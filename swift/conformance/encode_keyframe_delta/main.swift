// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

// Write `keyframe-delta` files through the Swift binding, for the gate that grades them.
//
// The other direction from `decode_streamed` and `decode_indexed`. Those two prove Swift
// reads what the corpus contains; this one produces files for `swift/keyframe-delta-
// roundtrip.sh` to hand to the Python reference, so the claim the matrix records is that a
// file Swift wrote reconstructs identically in an implementation that shares no code with
// it — not that Swift's writer and Swift's reader agree with each other.
//
// The sequences mirror `tests/conformance/generate.py`'s keyframe-delta variants, so four of
// them can additionally be compared against the committed corpus. They are rebuilt here
// rather than read out of the corpus because a written file has to come from a *population*,
// and the corpus stores files and their expected reconstructions — not the populations that
// produced them.
//
// Usage: encode_keyframe_delta <out-dir>
//        prints one `name<TAB>corpus|swift-only<TAB>note` line per file written.

import FourDGS
import Foundation

let duration = 8.0
let steps = 8

func t0(_ i: Int) -> Double { Double(i) * (duration / Double(steps)) }

/// A population at one instant: finite sigma, one shared full-clip window. Mirrors
/// `_kd_gaussians`.
func population(_ positions: [[Float]]) -> GaussianState {
    let n = positions.count
    return GaussianState(
        count: n,
        positions: positions.flatMap { $0 },
        scales: Array(repeating: Float(0.05), count: n * 3),
        rotations: (0..<n).flatMap { _ in [Float(0), 0, 0, 1] },
        colors: (0..<n).flatMap { _ in [Float(0.6), 0.4, 0.2, 0.9] },
        motions: Array(repeating: Float(0), count: n * 3),
        muT: Array(repeating: Float(0), count: n),
        sigmaT: Array(repeating: Float(100), count: n),
        winLo: Array(repeating: Float(0), count: n),
        winHi: Array(repeating: Float(duration), count: n),
        shDegree: 0, sh: [])
}

/// Four gaussians that drift. Every delta is a pure update. Mirrors `_kd_drift_sequence`.
func driftSequence() -> [KeyframeDeltaSample] {
    (0..<steps).map { i in
        let f = Float(i)
        return KeyframeDeltaSample(
            t0: t0(i), ids: [0, 1, 2, 3],
            gaussians: population([[f * 0.1, 0, 0], [1, f * 0.05, 0], [0, 1, f * 0.03], [1, 1, 0]]))
    }
}

/// The same drift with a birth (id 4, sample 2) and a death (id 2, sample 5), so deltas carry
/// birth and death groups and not only updates. Mirrors `_kd_churn_sequence`.
func churnSequence() -> [KeyframeDeltaSample] {
    (0..<steps).map { i in
        let f = Float(i)
        var ids: [UInt32] = [0, 1, 2, 3]
        var rows: [[Float]] = [[f * 0.1, 0, 0], [1, f * 0.05, 0], [0, 1, 0], [1, 1, 0]]
        if i >= 2 {
            ids.append(4)
            rows.append([2, 2, f * 0.02])
        }
        if i >= 5, let dead = ids.firstIndex(of: 2) {
            ids.remove(at: dead)
            rows.remove(at: dead)
        }
        return KeyframeDeltaSample(t0: t0(i), ids: ids, gaussians: population(rows))
    }
}

/// Six gaussians spread across three validity windows, two per window, with the ids rotated
/// each sample.
///
/// Not a corpus variant — the corpus one gives every row a distinct sigma and colour, which
/// this does not — but it reaches two things the others cannot. The Window Table gets more
/// than one entry, so a binding that passed `winLo`/`winHi` in the wrong order or dropped a
/// column writes a file whose gaussians reconstruct on the wrong window. And the ids stop
/// matching row order, so a writer that quietly numbered rows instead of carrying the id
/// stream produces a different population at every instant.
func multiWindowSequence() -> [KeyframeDeltaSample] {
    let windows: [(Float, Float)] = [(0, Float(duration)), (0, 2), (4, Float(duration))]
    return (0..<steps).map { i in
        let f = Float(i)
        let n = 6
        var ids: [UInt32] = [0, 1, 2, 3, 4, 5]
        ids.rotate(by: i % n)
        let rows = ids.map { id -> [Float] in
            let k = Float(id)
            return [k * 0.1 + f * 0.05, k * 0.2, f * 0.01]
        }
        var g = population(rows)
        // Window membership is a property of the gaussian, not of the step: `window_index` is
        // GOP-invariant (spec §11.5), so it is a function of the id alone.
        let lo = ids.map { windows[Int($0) / 2].0 }
        let hi = ids.map { windows[Int($0) / 2].1 }
        // `mu_t` sits inside each gaussian's own window; a birth time outside it would leave
        // the marginal doing the work the window is there to do.
        let mu = ids.map { windows[Int($0) / 2].0 }
        g = GaussianState(
            count: n, positions: g.positions, scales: g.scales, rotations: g.rotations,
            colors: g.colors, motions: g.motions, muT: mu, sigmaT: g.sigmaT, winLo: lo, winHi: hi,
            shDegree: 0, sh: [])
        return KeyframeDeltaSample(t0: t0(i), ids: ids, gaussians: g)
    }
}

extension Array {
    fileprivate mutating func rotate(by n: Int) {
        guard !isEmpty, n % count != 0 else { return }
        let k = n % count
        self = Array(self[k...] + self[..<k])
    }
}

/// `(file name, in corpus, samples, cadence, delta mode)`.
///
/// `inCorpus` is the claim the gate holds this variant to, and it is stated here rather than
/// inferred from whether `tests/conformance/data/keyframe/<name>.json` happens to exist. A
/// name is the only thing joining a variant to its expectation, and a name that drifts —
/// renamed here, renamed there, a flag added to the corpus's cross-product — would otherwise
/// turn the corpus comparison off silently and leave the gate reporting agreement. Declared,
/// a drift is a missing expectation for a variant that said it had one, which is a failure.
let variants:
    [(
        name: String, inCorpus: Bool, samples: [KeyframeDeltaSample], keyframeEvery: UInt32,
        mode: DeltaMode
    )] = [
        ("KeyframeOnly-UseChunkIndex-UseCrc-UseStatistics", true, churnSequence(), 1, .chained),
        ("KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics", true, driftSequence(), 4, .chained),
        (
            "KeyframeDeltaChurn-UseChunkIndex-UseCrc-UseStatistics", true, churnSequence(), 4,
            .chained
        ),
        (
            "KeyframeDeltaModesMixed-UseChunkIndex-UseCrc-UseStatistics", true, churnSequence(), 4,
            .keyframeReferenced
        ),
        ("SwiftMultiWindow", false, multiWindowSequence(), 4, .chained),
    ]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("encode_keyframe_delta: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: encode_keyframe_delta <out-dir>")
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

for variant in variants {
    var options = KeyframeDeltaWriteOptions()
    options.keyframeEvery = variant.keyframeEvery
    options.deltaMode = variant.mode
    options.library = "4dgs swift conformance"

    let bytes: [UInt8]
    do {
        bytes = try KeyframeDeltaWriter.encode(
            variant.samples, durationSec: duration, options: options)
        // Determinism is part of the claim: a writer whose output depends on hash order or on
        // an uninitialised byte makes every downstream diff unreproducible, and the gate that
        // would catch it is this one.
        let again = try KeyframeDeltaWriter.encode(
            variant.samples, durationSec: duration, options: options)
        guard bytes == again else { fail("\(variant.name): two encodes differ") }
    } catch {
        fail("\(variant.name): \(error)")
    }

    let path = directory.appendingPathComponent("\(variant.name).4dgs")
    do {
        try Data(bytes).write(to: path)
    } catch {
        fail("\(variant.name): \(error)")
    }
    print(
        "\(variant.name)\t\(variant.inCorpus ? "corpus" : "swift-only")\t"
            + "\(variant.samples.count) samples, cadence \(variant.keyframeEvery), "
            + "\(variant.mode == .chained ? "chained" : "keyframe-referenced"), \(bytes.count) bytes"
    )
}
