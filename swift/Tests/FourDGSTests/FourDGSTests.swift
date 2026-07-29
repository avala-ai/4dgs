// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import FourDGS

/// What the package can prove today: the §3 arithmetic, the magic check, and that the
/// errors say which byte and what was expected. Decode itself is the C ABI seam, and these
/// tests assert that it fails loudly rather than quietly.
final class TimeTests: XCTestCase {

    private func gaussian(muT: Float, sigmaT: Float, winLo: Float, winHi: Float) -> Gaussian {
        Gaussian(
            position: Vector3(1, 2, 3), scale: Vector3(0.1, 0.1, 0.1), rotation: Quaternion(0, 0, 0, 1),
            color: SIMD4<Float>(0.5, 0.5, 0.5, 0.8), motion: Vector3(10, 0, 0), muT: muT, sigmaT: sigmaT,
            winLo: winLo, winHi: winHi)
    }

    func testMarginalPeaksAtBirthTime() {
        let g = gaussian(muT: 2, sigmaT: 0.5, winLo: 0, winHi: 10)
        XCTAssertEqual(g.marginal(at: 2), 1, accuracy: 1e-12)
        XCTAssertEqual(g.marginal(at: 2.5), 0.6065306597, accuracy: 1e-9)
        XCTAssertEqual(g.marginal(at: 1.5), g.marginal(at: 2.5), accuracy: 1e-12)
    }

    func testNeverFadingGaussianHasMarginalOneEverywhere() {
        let g = gaussian(muT: 2, sigmaT: .infinity, winLo: 1, winHi: 3)
        XCTAssertTrue(g.neverFades)
        XCTAssertEqual(g.marginal(at: 1), 1)
        XCTAssertEqual(g.marginal(at: 2.999), 1)
    }

    func testValidityWindowIsTheHardGate() {
        // A never-fading gaussian has marginal 1 outside its window too. The window, not
        // the marginal, is what makes it absent there.
        let g = gaussian(muT: 2, sigmaT: .infinity, winLo: 1, winHi: 3)
        XCTAssertEqual(g.marginal(at: 5), 1)
        XCTAssertFalse(g.isLive(at: 5, cutoff: 0.05))
        XCTAssertTrue(g.isLive(at: 1, cutoff: 0.05))
        // Half-open: the upper bound is not inside the window.
        XCTAssertFalse(g.isLive(at: 3, cutoff: 0.05))
    }

    func testCutoffComesFromTheFile() {
        let g = gaussian(muT: 0, sigmaT: 1, winLo: -100, winHi: 100)
        let marginal = g.marginal(at: 2)  // exp(-2) ≈ 0.1353
        XCTAssertTrue(marginal > 0.05 && marginal < 0.2)
        XCTAssertTrue(g.isLive(at: 2, cutoff: 0.05))
        XCTAssertFalse(g.isLive(at: 2, cutoff: 0.2))
    }

    func testCenterMovesWithVelocityFromBirthTime() {
        let g = gaussian(muT: 2, sigmaT: 1, winLo: 0, winHi: 10)
        XCTAssertEqual(g.center(at: 2), Vector3(1, 2, 3))
        XCTAssertEqual(g.center(at: 3), Vector3(11, 2, 3))
        XCTAssertEqual(g.center(at: 1), Vector3(-9, 2, 3))
    }

    func testStateAtTimeMovesAndFades() {
        let g = gaussian(muT: 0, sigmaT: 1, winLo: 0, winHi: 10)
        let s = g.state(at: 1)
        XCTAssertEqual(s.position.x, 10, accuracy: 1e-5)
        XCTAssertEqual(s.color.w, 0.8 * Float(_exp(-0.5)), accuracy: 1e-6)
        // Everything else is untouched — decode ends at state, it does not reinterpret it.
        XCTAssertEqual(s.scale, g.scale)
        XCTAssertEqual(s.rotation, g.rotation)
    }

    func testLifetimeConstantUsesTheHeadersCutoff() {
        // §6.3: K = sqrt(-2 ln cutoff). A decoder that hardcodes the default decodes
        // different velocities than the encoder wrote for any file that declares another.
        var header = Header(
            profile: "", library: "t", durationSec: 1, gaussianCount: 0, cutoff: 0.05,
            temporalModel: "gaussian-birth", aabb: [0, 0, 0, 1, 1, 1], shDegree: 0, hasAudio: false,
            hasCompressedChunks: false, attributes: [:])
        XCTAssertEqual(header.lifetimeConstantK, 2.4477468306808347, accuracy: 1e-12)
        header.cutoff = 0.01
        XCTAssertEqual(header.lifetimeConstantK, 3.034854258770293, accuracy: 1e-12)
    }
}

final class LiveTests: XCTestCase {

    /// Three gaussians: one inside its window, one outside it, one faded below cutoff.
    private func state() -> GaussianState {
        GaussianState(
            count: 3,
            positions: [0, 0, 0, 1, 1, 1, 2, 2, 2],
            scales: [1, 1, 1, 1, 1, 1, 1, 1, 1],
            rotations: [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1],
            colors: [1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 1, 1],
            motions: [0, 0, 0, 0, 0, 0, 0, 0, 0],
            muT: [1, 1, 1],
            sigmaT: [.infinity, .infinity, 0.1],
            winLo: [0, 5, 0],
            winHi: [2, 7, 2],
            shDegree: 0, sh: [])
    }

    func testLiveKeepsOnlyWhatSection3Allows() {
        let live = state().live(at: 1.0, cutoff: 0.05)
        XCTAssertEqual(live.count, 2)  // in-window never-fader, and the sharp one at its peak
        let late = state().live(at: 1.5, cutoff: 0.05)
        XCTAssertEqual(late.count, 1)  // the sharp one has faded to exp(-12.5)
    }

    func testLiveIsIdentityWhenEverythingIsLive() {
        let s = GaussianState(
            count: 1, positions: [0, 0, 0], scales: [1, 1, 1], rotations: [0, 0, 0, 1],
            colors: [1, 1, 1, 1], motions: [0, 0, 0], muT: [0], sigmaT: [.infinity], winLo: [0], winHi: [1],
            shDegree: 0, sh: [])
        XCTAssertEqual(s.live(at: 0.5, cutoff: 0.05), s)
    }

    func testGatherCarriesSphericalHarmonicsAlong() {
        // Degree 1: 3 coefficients per component, 9 bytes per gaussian.
        let s = GaussianState(
            count: 2, positions: [0, 0, 0, 1, 1, 1], scales: [1, 1, 1, 1, 1, 1],
            rotations: [0, 0, 0, 1, 0, 0, 0, 1], colors: [1, 1, 1, 1, 1, 1, 1, 1],
            motions: [0, 0, 0, 0, 0, 0], muT: [0, 0], sigmaT: [.infinity, .infinity], winLo: [0, 5],
            winHi: [1, 6], shDegree: 1,
            sh: [1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 18, 19])
        XCTAssertEqual(s.shCoefficientsPerComponent, 3)
        let live = s.live(at: 0.5, cutoff: 0.05)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.sh, [1, 2, 3, 4, 5, 6, 7, 8, 9])
    }

    func testConcatenationAcrossChunks() {
        let chunk = DecodedChunk(t0: 0, t1: 2, level: 0, gaussians: state())
        let both = GaussianState.live(in: [chunk, chunk], at: 1.0, cutoff: 0.05)
        XCTAssertEqual(both.count, 4)
    }
}

final class MagicTests: XCTestCase {

    func testAcceptsTheMagic() throws {
        var reader = InMemoryReader(Core.magic + [0x01])
        XCTAssertNoThrow(try Core.validateMagic(&reader))
    }

    func testRejectsSomethingElseEntirely() {
        var reader = InMemoryReader(Array("not a splat".utf8))
        XCTAssertThrowsError(try Core.validateMagic(&reader)) { error in
            guard case FourDGSError.notFourDGS(let offset, _) = error else {
                return XCTFail("expected notFourDGS, got \(error)")
            }
            XCTAssertEqual(offset, 0)
            XCTAssertTrue("\(error)".contains("expected magic 89 34 44 47 53 31 0d 0a"))
        }
    }

    func testDiagnosesAFutureVersionSeparately() {
        // A reader that does not implement a version must refuse the file rather than
        // guess — and must say that is what happened, because the fix is a newer reader.
        var bytes = Core.magic
        bytes[5] = 0x32  // ASCII '2'
        var reader = InMemoryReader(bytes)
        XCTAssertThrowsError(try Core.validateMagic(&reader)) { error in
            guard case FourDGSError.unsupportedMajorVersion(let found, let supported) = error else {
                return XCTFail("expected unsupportedMajorVersion, got \(error)")
            }
            XCTAssertEqual(found, 0x32)
            XCTAssertEqual(supported, 0x31)
        }
    }

    func testShortInputIsTruncatedNotGarbage() {
        var reader = InMemoryReader(Array(Core.magic[0..<4]))
        XCTAssertThrowsError(try Core.validateMagic(&reader)) { error in
            guard case FourDGSError.truncated(_, let record, let needed, let available) = error else {
                return XCTFail("expected truncated, got \(error)")
            }
            XCTAssertEqual(record, "magic")
            XCTAssertEqual(needed, 8)
            XCTAssertEqual(available, 4)
        }
    }
}

final class SeamTests: XCTestCase {

    /// The seam fails loudly. A binding whose unimplemented paths returned empty data would
    /// pass a conformance run by decoding nothing, which is the failure mode this asserts
    /// against.
    func testDecodeIsNotImplementedYetAndSaysSo() {
        let reader = InMemoryReader(Core.magic + Array(repeating: 0, count: 64))
        XCTAssertThrowsError(try StreamedReader(reader)) { error in
            guard case FourDGSError.notImplemented(let what) = error else {
                return XCTFail("expected notImplemented, got \(error)")
            }
            XCTAssertEqual(what, "streamed decode")
        }
        XCTAssertThrowsError(try IndexedReader(reader)) { error in
            guard case FourDGSError.notImplemented = error else {
                return XCTFail("expected notImplemented, got \(error)")
            }
        }
    }

    func testMagicIsCheckedBeforeTheSeamIsReached() {
        // Order matters: garbage should be diagnosed as garbage, not as "not implemented".
        let reader = InMemoryReader(Array(repeating: 0x41, count: 64))
        XCTAssertThrowsError(try StreamedReader(reader)) { error in
            guard case FourDGSError.notFourDGS = error else {
                return XCTFail("expected notFourDGS, got \(error)")
            }
        }
    }
}

final class ReaderTests: XCTestCase {

    func testInMemoryReaderShortReadsAtTheEndRatherThanThrowing() throws {
        var reader = InMemoryReader([1, 2, 3, 4])
        XCTAssertEqual(try reader.read(offset: 2, count: 10), [3, 4])
        XCTAssertEqual(try reader.read(offset: 9, count: 2), [])
        XCTAssertEqual(try reader.byteCount(), 4)
    }

    func testNegativeRangesAreRefused() {
        var reader = InMemoryReader([1, 2, 3, 4])
        XCTAssertThrowsError(try reader.read(offset: -1, count: 2))
    }

    func testSeekPicksEveryChunkWhoseIntervalContainsTheInstant() {
        let entries = [
            ChunkIndexEntry(t0: 0, t1: 1, chunkOffset: 0, chunkLength: 10, gaussianCount: 1, bands: []),
            ChunkIndexEntry(t0: 0.5, t1: 2, chunkOffset: 10, chunkLength: 10, gaussianCount: 1, bands: []),
            ChunkIndexEntry(t0: 2, t1: 3, chunkOffset: 20, chunkLength: 10, gaussianCount: 1, bands: []),
        ]
        let scene = Scene(
            header: Header(
                profile: "", library: "t", durationSec: 3, gaussianCount: 3, cutoff: 0.05,
                temporalModel: "gaussian-birth", aabb: [0, 0, 0, 1, 1, 1], shDegree: 0, hasAudio: false,
                hasCompressedChunks: false, attributes: [:]),
            chunkIndex: entries)
        XCTAssertEqual(scene.chunks(containing: 0.75).count, 2)
        XCTAssertEqual(scene.chunks(containing: 2.0).count, 1)  // half-open: not the second
        XCTAssertEqual(scene.chunks(containing: 9.0).count, 0)
    }

    func testAbsentAudioIsAValueNotAnError() {
        let scene = Scene(
            header: Header(
                profile: "", library: "t", durationSec: 1, gaussianCount: 0, cutoff: 0.05,
                temporalModel: "gaussian-birth", aabb: [0, 0, 0, 0, 0, 0], shDegree: 0, hasAudio: false,
                hasCompressedChunks: false, attributes: [:]))
        XCTAssertNil(scene.audio)
        XCTAssertFalse(scene.header.hasAudio)
    }
}
