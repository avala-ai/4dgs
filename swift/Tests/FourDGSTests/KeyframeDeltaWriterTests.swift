// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import FourDGS

/// What the `keyframe-delta` writer has to prove.
///
/// The writer is a binding, so what is at risk is not the arithmetic — that lives in the
/// core and the conformance corpus already pins it — but everything around it: that the
/// samples, the ids and the options cross the ABI in the right order and the right shape,
/// that a file this package writes is one this package reads back, and that the refusals the
/// model depends on still arrive as typed errors rather than as a file nobody notices is
/// wrong.
///
/// Every claim below is made through the reader, on **both read paths** where it can be. The
/// two fail differently: the streamed path never looks at the index, so a wrong chunk offset
/// or a wrong reference decodes cleanly there and only the indexed walk notices. A writer
/// checked on one path is half-checked.
final class KeyframeDeltaWriterTests: XCTestCase {

    // MARK: - Sequences

    /// The clip length and step count the conformance corpus's keyframe-delta variants use,
    /// so a sequence built here lands on the same chunk boundaries and the same probe
    /// instants as the committed expectation.
    private static let duration = 8.0
    private static let steps = 8

    /// A population at one instant: finite `sigmaT`, one shared full-clip window.
    ///
    /// Mirrors `_kd_gaussians` in `tests/conformance/generate.py`. `sigmaT` is finite because
    /// this reference encoder requires it, and the window spans the clip so nothing here is
    /// removed by §3's visibility gate — what these tests are about is composition, and a
    /// window that shuts would decide the population before composition got a say.
    private func population(_ positions: [[Float]]) -> GaussianState {
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
            winHi: Array(repeating: Float(Self.duration), count: n),
            shDegree: 0, sh: [])
    }

    private func t0(_ i: Int) -> Double {
        Double(i) * (Self.duration / Double(Self.steps))
    }

    /// Four gaussians that drift. No births and no deaths, so every delta is a pure update —
    /// the plain keyframe-delta shape. Mirrors `_kd_drift_sequence`.
    private func driftSequence() -> [KeyframeDeltaSample] {
        (0..<Self.steps).map { i in
            let f = Float(i)
            return KeyframeDeltaSample(
                t0: t0(i), ids: [0, 1, 2, 3],
                gaussians: population([
                    [f * 0.1, 0, 0], [1, f * 0.05, 0], [0, 1, f * 0.03], [1, 1, 0],
                ]))
        }
    }

    /// The same drift with one birth (id 4, from sample 2) and one death (id 2, from sample
    /// 5), so deltas carry birth and death groups and not only updates. Mirrors
    /// `_kd_churn_sequence`.
    private func churnSequence() -> [KeyframeDeltaSample] {
        (0..<Self.steps).map { i in
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

    // MARK: - Reading the result back

    /// One probe of the canonical summary the core computes from a written file.
    private struct Probe {
        var t: Double
        var liveCount: Int
        var ids: [String]
        var positions: [[Double]]
    }

    private func summary(_ bytes: [UInt8], indexed: Bool) throws -> [String: Any] {
        let json = try keyframeDeltaStatesJson(bytes, indexed: indexed)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func probes(_ bytes: [UInt8], indexed: Bool) throws -> [Probe] {
        try readProbes(from: try summary(bytes, indexed: indexed))
    }

    private func readProbes(from document: [String: Any]) throws -> [Probe] {
        let states = try XCTUnwrap(document["states"] as? [[String: Any]])
        return try states.map { state in
            let sample = try XCTUnwrap(state["sample"] as? [String: Any])
            return Probe(
                t: try XCTUnwrap(state["t"] as? Double),
                liveCount: try XCTUnwrap(Int(XCTUnwrap(state["liveCount"] as? String))),
                ids: try XCTUnwrap(sample["gaussianIds"] as? [String]),
                positions: try XCTUnwrap(sample["positions"] as? [[Double]]))
        }
    }

    /// The reconstruction alone, as one comparable string.
    ///
    /// The summary also carries the chunk table, and that is *supposed* to differ between two
    /// encodings of the same sequence — a different cadence or a different `delta_mode` writes
    /// different records. What may not differ is what those records reconstruct to.
    private func reconstruction(_ bytes: [UInt8], indexed: Bool) throws -> String {
        let states = try XCTUnwrap(try summary(bytes, indexed: indexed)["states"])
        let data = try JSONSerialization.data(withJSONObject: states, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Two encodings of one sequence must place the same gaussians in the same places.
    ///
    /// Population and geometry, deliberately not the whole summary. Where the keyframes fall
    /// is *allowed* to move the opacity: a keyframe restates every live gaussian's `mu_t` at
    /// its own `t0` (spec §11.3), which is what lets an untouched gaussian keep extrapolating
    /// for free — and moving a birth time moves the temporal marginal, so the aggregate
    /// opacity at a probe legitimately differs between two cadences. What may never differ is
    /// which gaussians are live and where they are.
    private func assertSameGeometry(
        _ mine: [Probe], _ theirs: [Probe], accuracy: Double = 1e-3,
        _ label: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(mine.count, theirs.count, "probe count \(label)", file: file, line: line)
        for (a, b) in zip(mine, theirs) {
            XCTAssertEqual(a.t, b.t, accuracy: 1e-9, label, file: file, line: line)
            XCTAssertEqual(
                a.liveCount, b.liveCount, "live count at t \(b.t) \(label)", file: file, line: line)
            XCTAssertEqual(a.ids, b.ids, "ids at t \(b.t) \(label)", file: file, line: line)
            guard a.positions.count == b.positions.count else {
                XCTFail("row count at t \(b.t) \(label)", file: file, line: line)
                continue
            }
            for row in 0..<b.positions.count {
                for axis in 0..<3 {
                    XCTAssertEqual(
                        a.positions[row][axis], b.positions[row][axis], accuracy: accuracy,
                        "position \(axis) of row \(row) at t \(b.t) \(label)", file: file, line: line)
                }
            }
        }
    }

    /// Which probe carries the state sample `i` was written from.
    ///
    /// The core probes each state chunk twice — at its `t0` and midway through — so a
    /// sequence of `steps` samples yields `2 * steps + 1` probes and the sample's own instant
    /// is the even one. Indexing these one-for-one would compare each sample with the middle
    /// of the previous chunk, which is a real state and the wrong one.
    private func probeIndex(ofSample i: Int) -> Int { i * 2 }

    /// Each state chunk's kind, in file order: `keyframe` or `delta`.
    private func chunkKinds(_ bytes: [UInt8]) throws -> [String] {
        let chunks = try XCTUnwrap(try summary(bytes, indexed: true)["chunks"] as? [[String: Any]])
        return try chunks.map { try XCTUnwrap($0["kind"] as? String) }
    }

    // MARK: - The file this package writes is one it reads

    func testAWrittenSequenceDeclaresTheKeyframeDeltaModel() throws {
        let bytes = try KeyframeDeltaWriter.encode(driftSequence(), durationSec: Self.duration)
        XCTAssertFalse(bytes.isEmpty)
        // An opened scene refuses the model, so a consumer peeks the Header first. A writer
        // that produced anything else here would send every reader down the wrong path.
        XCTAssertEqual(try peekTemporalModel(bytes), "keyframe-delta")
    }

    func testBothReadPathsAgreeOnAWrittenSequence() throws {
        let bytes = try KeyframeDeltaWriter.encode(churnSequence(), durationSec: Self.duration)
        // Byte-for-byte on the summary, not lane by lane: the streamed path composes front to
        // back and never reads the index, so a chunk offset or a reference the writer got
        // wrong reconstructs cleanly there and disagrees only here.
        XCTAssertEqual(
            try keyframeDeltaStatesJson(bytes, indexed: false),
            try keyframeDeltaStatesJson(bytes, indexed: true))
    }

    func testTheReconstructionIsThePopulationThatWentIn() throws {
        let samples = driftSequence()
        let bytes = try KeyframeDeltaWriter.encode(samples, durationSec: Self.duration)
        let read = try probes(bytes, indexed: false)

        XCTAssertEqual(read.count, 2 * Self.steps + 1)
        for (i, sample) in samples.enumerated() {
            let probe = read[probeIndex(ofSample: i)]
            XCTAssertEqual(probe.liveCount, sample.ids.count, "live count at sample \(i)")
            XCTAssertEqual(probe.ids, sample.ids.map(String.init), "ids at sample \(i)")
            for row in 0..<sample.ids.count {
                for axis in 0..<3 {
                    XCTAssertEqual(
                        probe.positions[row][axis],
                        Double(sample.gaussians.positions[row * 3 + axis]),
                        // Well inside the default profile's position bound at this scale.
                        // The claim is that the writer preserved the scene, which no amount
                        // of decoder agreement can make: an encoder that displaced every
                        // position produces a file every decoder reads the same wrong way.
                        accuracy: 1e-3,
                        "position \(axis) of row \(row) at sample \(i)")
                }
            }
        }
    }

    func testABirthAndADeathChangeTheComposedPopulation() throws {
        let bytes = try KeyframeDeltaWriter.encode(churnSequence(), durationSec: Self.duration)
        for indexed in [false, true] {
            let read = try probes(bytes, indexed: indexed)
            // Four to start, five once id 4 is born at sample 2, four again once id 2 dies at
            // sample 5. A writer that dropped the death group would report five throughout.
            XCTAssertEqual(read[probeIndex(ofSample: 0)].ids, ["0", "1", "2", "3"], "indexed: \(indexed)")
            XCTAssertEqual(
                read[probeIndex(ofSample: 1)].ids, ["0", "1", "2", "3"], "indexed: \(indexed)")
            XCTAssertEqual(
                read[probeIndex(ofSample: 2)].ids, ["0", "1", "2", "3", "4"], "indexed: \(indexed)")
            XCTAssertEqual(
                read[probeIndex(ofSample: 4)].ids, ["0", "1", "2", "3", "4"], "indexed: \(indexed)")
            XCTAssertEqual(
                read[probeIndex(ofSample: 5)].ids, ["0", "1", "3", "4"], "indexed: \(indexed)")
            XCTAssertEqual(
                read[probeIndex(ofSample: Self.steps - 1)].ids, ["0", "1", "3", "4"],
                "indexed: \(indexed)")
        }
    }

    // MARK: - The options mean what the model says they mean

    func testChainedAndKeyframeReferencedDeltasReconstructTheSame() throws {
        let samples = churnSequence()
        var chained = KeyframeDeltaWriteOptions()
        chained.keyframeEvery = 4
        chained.deltaMode = .chained
        var referenced = chained
        referenced.deltaMode = .keyframeReferenced

        let a = try KeyframeDeltaWriter.encode(samples, durationSec: Self.duration, options: chained)
        let b = try KeyframeDeltaWriter.encode(
            samples, durationSec: Self.duration, options: referenced)

        // Different files, identical reconstructions. This is §11.7 as a test: chained deltas
        // accumulate no error at any depth, because a delta is a difference of bins and never
        // a quantization of a difference. An encoder that subtracted floats and quantized
        // afterwards would pass every other test here and fail this one at depth three.
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(
            try reconstruction(a, indexed: false), try reconstruction(b, indexed: false))
    }

    func testACadenceOfOneWritesEveryStateWhole() throws {
        let samples = churnSequence()
        var everyFrame = KeyframeDeltaWriteOptions()
        everyFrame.keyframeEvery = 1
        let whole = try KeyframeDeltaWriter.encode(
            samples, durationSec: Self.duration, options: everyFrame)
        let deltas = try KeyframeDeltaWriter.encode(samples, durationSec: Self.duration)

        // Every chunk a keyframe: the cadence-one shape the registry's `frame-sequence`
        // reservation describes, and the one a producer picks when every instant must be
        // seekable in a single record.
        XCTAssertEqual(try chunkKinds(whole), Array(repeating: "keyframe", count: Self.steps))
        XCTAssertEqual(
            try chunkKinds(deltas), ["keyframe"] + Array(repeating: "delta", count: Self.steps - 1))
        // Two different files, one population in the same places — which is what makes the
        // cadence a rate-control choice rather than a semantic one. (It is not reliably the
        // *larger* file: one deflate stream over a whole restatement can beat eight small
        // delta blocks and their record headers, so size is the wrong thing to assert.)
        assertSameGeometry(
            try probes(whole, indexed: true), try probes(deltas, indexed: true), "cadence 1 vs 8")
    }

    func testForcingAKeyframeChangesTheRecordsAndNotTheReconstruction() throws {
        let samples = driftSequence()
        var forced = KeyframeDeltaWriteOptions()
        forced.keyframeAt = [5]
        let plain = try KeyframeDeltaWriter.encode(samples, durationSec: Self.duration)
        let cut = try KeyframeDeltaWriter.encode(samples, durationSec: Self.duration, options: forced)

        XCTAssertEqual(try chunkKinds(plain)[5], "delta")
        XCTAssertEqual(try chunkKinds(cut)[5], "keyframe")
        assertSameGeometry(
            try probes(plain, indexed: true), try probes(cut, indexed: true), "forced keyframe")
    }

    func testEncodingTheSameSequenceTwiceProducesTheSameBytes() throws {
        let samples = churnSequence()
        XCTAssertEqual(
            try KeyframeDeltaWriter.encode(samples, durationSec: Self.duration),
            try KeyframeDeltaWriter.encode(samples, durationSec: Self.duration))
    }

    // MARK: - What the writer refuses

    func testAnEmptySequenceIsRefused() {
        XCTAssertThrowsError(try KeyframeDeltaWriter.encode([], durationSec: Self.duration))
    }

    func testIdsAndGaussiansAreOneList() {
        let sample = KeyframeDeltaSample(
            t0: 0, ids: [0, 1], gaussians: population([[0, 0, 0], [1, 0, 0], [2, 0, 0]]))
        XCTAssertThrowsError(try KeyframeDeltaWriter.encode([sample], durationSec: 1)) { error in
            // Named, not merely refused: the message says how many of each there were, because
            // a caller that mis-slices one array cannot tell which array from a bare type.
            XCTAssertTrue(
                "\(error)".contains("3 gaussians") && "\(error)".contains("2 ids"), "\(error)")
        }
    }

    func testAGopInvariantChangeInsideAGroupIsRefused() {
        // sigma_t derives the per-gaussian grids for motion and mu_t, so a bin difference
        // across a change in it subtracts bins that live on two different grids (spec §11.5).
        // That is not an approximation, it is a number with no meaning — and it decodes
        // silently into a wrong velocity rather than into an error, which is exactly why the
        // encoder has to catch it and the decoder cannot.
        var second = population([[0, 0, 0]])
        second = GaussianState(
            count: 1, positions: second.positions, scales: second.scales,
            rotations: second.rotations, colors: second.colors, motions: second.motions,
            muT: second.muT, sigmaT: [3], winLo: second.winLo, winHi: second.winHi,
            shDegree: 0, sh: [])
        let samples = [
            KeyframeDeltaSample(t0: 0, ids: [7], gaussians: population([[0, 0, 0]])),
            KeyframeDeltaSample(t0: 4, ids: [7], gaussians: second),
        ]
        XCTAssertThrowsError(try KeyframeDeltaWriter.encode(samples, durationSec: 8)) { error in
            XCTAssertTrue("\(error)".contains("7"), "\(error)")
            // The fix is always available to the caller, and the message has to say so.
            XCTAssertTrue("\(error)".lowercased().contains("keyframe"), "\(error)")
        }
    }

    func testANonFiniteSigmaIsRefusedRatherThanRounded() {
        // `+inf` is legal in the format — it is how a gaussian says it never fades — and this
        // reference encoder does not write one. Refusing beats silently substituting a finite
        // sigma, which would change the reconstruction everywhere and look like content.
        var g = population([[0, 0, 0]])
        g = GaussianState(
            count: 1, positions: g.positions, scales: g.scales, rotations: g.rotations,
            colors: g.colors, motions: g.motions, muT: g.muT, sigmaT: [.infinity],
            winLo: g.winLo, winHi: g.winHi, shDegree: 0, sh: [])
        let samples = [KeyframeDeltaSample(t0: 0, ids: [0], gaussians: g)]
        XCTAssertThrowsError(try KeyframeDeltaWriter.encode(samples, durationSec: 1))
    }

    func testAProfileThisEncoderDoesNotQuantizeAgainstIsRefused() {
        var options = KeyframeDeltaWriteOptions()
        options.profile = "lossless"
        XCTAssertThrowsError(
            try KeyframeDeltaWriter.encode(driftSequence(), durationSec: Self.duration, options: options)
        ) { error in
            // The three it does take are in the message: an unknown value is a typo far more
            // often than it is a request for something new.
            XCTAssertTrue("\(error)".contains("fine"), "\(error)")
            XCTAssertTrue("\(error)".contains("coarse"), "\(error)")
        }
    }

    func testEachProfileIsQuantizedAgainstDifferently() throws {
        var coarse = KeyframeDeltaWriteOptions()
        coarse.profile = "coarse"
        var fine = KeyframeDeltaWriteOptions()
        fine.profile = "fine"
        let a = try KeyframeDeltaWriter.encode(
            driftSequence(), durationSec: Self.duration, options: coarse)
        let b = try KeyframeDeltaWriter.encode(
            driftSequence(), durationSec: Self.duration, options: fine)
        // Proves the option reached the core rather than being accepted and dropped: the two
        // are quantized on different grids, so they cannot be the same bytes.
        XCTAssertNotEqual(a, b)
    }

    func testTheLibraryStringReachesTheHeader() throws {
        var options = KeyframeDeltaWriteOptions()
        options.library = "4dgs swift tests"
        let bytes = try KeyframeDeltaWriter.encode(
            driftSequence(), durationSec: Self.duration, options: options)
        // Read out of the bytes rather than through a reader, because an opened scene refuses
        // this model: the Header's `library` is a length-prefixed string in the first record.
        let needle = Array("4dgs swift tests".utf8)
        XCTAssertNotNil(
            bytes.indices.first { i in
                i + needle.count <= bytes.count && Array(bytes[i..<(i + needle.count)]) == needle
            })
    }

    // MARK: - Against the corpus

    func testAWrittenSequenceReconstructsAsTheCorpusSaysItShould() throws {
        // The strongest claim available in-process: the same populations the corpus generator
        // builds, encoded here, reconstruct to the population the *Python* reference recorded
        // for them. The two encoders are independent, so this is not a decoder agreeing with
        // its own writer.
        let expectation = try corpusStates("KeyframeDelta-UseChunkIndex-UseCrc-UseStatistics")
        var options = KeyframeDeltaWriteOptions()
        options.keyframeEvery = 4
        let bytes = try KeyframeDeltaWriter.encode(
            driftSequence(), durationSec: Self.duration, options: options)

        for indexed in [false, true] {
            assertSameGeometry(
                try probes(bytes, indexed: indexed), expectation, "corpus, indexed: \(indexed)")
        }
    }

    /// The committed canonical `states` for one corpus variant.
    ///
    /// The corpus is generated, not committed, so a checkout without it skips rather than
    /// fails — except on CI, where a missing corpus means the generate step did not run and
    /// silently skipping would hide it.
    private func corpusStates(_ name: String) throws -> [Probe] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let directory =
            ProcessInfo.processInfo.environment["FOURDGS_CORPUS"].map {
                URL(fileURLWithPath: $0)
            } ?? root.appendingPathComponent("tests/conformance/data")
        let file = directory.appendingPathComponent("keyframe/\(name).json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            if ProcessInfo.processInfo.environment["CI"] != nil {
                XCTFail("no corpus at \(file.path); the generate step did not run")
            }
            throw XCTSkip("no corpus; run tests/conformance/generate.py first")
        }
        let committed = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        return try readProbes(from: try XCTUnwrap(committed as? [String: Any]))
    }
}
