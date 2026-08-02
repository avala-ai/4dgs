// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FourDGS

/// The two things the canonical JSON cannot say.
///
/// Every other row in the feature matrix is proved by a summary matching an expectation. These
/// two are not, and cannot be: a cut file is a *different* file, so no expectation describes
/// it; and never transferring a band you will not evaluate is a fact about the transport, not
/// about any decoded value. So the checks live in the runner, where a failure exits non-zero
/// and the harness reports it like a diff.
enum ExtraChecks {

    enum Failure: Error, CustomStringConvertible {
        case notReportedTruncated(what: String)
        case lostGaussians(what: String, got: Int, expected: Int)
        case gainedGaussians(what: String, got: Int, whole: Int)
        case noBytesMoved(chunk: Int, cap: Int)
        case capMovedMoreThanWider(chunk: Int, narrow: Int, narrowBytes: UInt64, wide: Int, wideBytes: UInt64)
        case capMovedNothingLess(chunk: Int, bytes: UInt64, degree: Int)
        case trackNotComposed(t: Double, gaussian: Int)

        var description: String {
            switch self {
            case .trackNotComposed(let t, let gaussian):
                return
                    "at t=\(t) gaussian \(gaussian) belongs to a tracked object but stateAt left it "
                    + "at the pose §3 alone would give — the Object Track was not composed"
            case .notReportedTruncated(let what):
                return "\(what) was not reported truncated"
            case .lostGaussians(let what, let got, let expected):
                return "\(what) lost gaussians: \(got) of \(expected)"
            case .gainedGaussians(let what, let got, let whole):
                return "\(what) decoded more gaussians than the whole file: \(got) against \(whole)"
            case .noBytesMoved(let chunk, let cap):
                return "chunk \(chunk) at band cap \(cap) reported moving no bytes at all"
            case .capMovedMoreThanWider(let chunk, let narrow, let narrowBytes, let wide, let wideBytes):
                return
                    "chunk \(chunk): band cap \(narrow) moves \(narrowBytes) bytes, more than cap \(wide)'s \(wideBytes) — a narrower cap must never transfer more"
            case .capMovedNothingLess(let chunk, let bytes, let degree):
                return
                    "chunk \(chunk): capping spherical harmonics at band 0 still moves \(bytes) bytes, the same as the full degree \(degree) — the bands are being transferred despite being capped away"
            }
        }
    }

    // MARK: - Truncated-file recovery

    /// Decode the same file cut short, twice, and insist on what survives.
    ///
    /// Nothing in the corpus is truncated, so this makes two files that are. The rule in both
    /// cases is the same: what preceded the cut must decode, and the reader must **say** it was
    /// cut rather than pass a short scene off as a complete one. Silence is the failure mode
    /// that matters — a decoder that returns fewer gaussians without comment is one a consumer
    /// cannot distinguish from a small file.
    /// `stateAt` composes Object Tracks; reconstructing by hand does not.
    ///
    /// The canonical JSON proves the *core* composes, because the `states` member comes
    /// from the core. What it cannot prove is that this binding's reconstruction surfaces
    /// that composition — a Swift caller could be handed §3-only poses while the summary
    /// looked perfect, and the feature matrix would claim something no check covers.
    ///
    /// So: somewhere among these probes, at least one gaussian belonging to a tracked
    /// object must come back from ``SceneReader/stateAt(_:options:)`` at a different place
    /// than ``Gaussian/state(at:)`` puts it. Aggregated across the probes rather than
    /// demanded at each, because a track is free to sit at the identity pose for part of
    /// its life — every corpus track does, early on — and a scene whose layer carries no
    /// track at all is excused entirely, since for it the composition *is* the identity.
    static func objectTracksAreComposed(
        _ scene: SceneReader, at times: [Double], layerHasTrack: Bool
    ) throws {
        guard layerHasTrack else { return }
        let resident = try scene.gaussians(at: times[0])
        guard resident.objectIds.contains(where: { $0 != 0 }) else { return }

        var firstMember: Int?
        for t in times {
            let composed = try scene.stateAt(t)
            let rest = try scene.gaussians(at: t)
            guard composed.count > 0, rest.objectIds.count == rest.count else { continue }

            for i in 0..<composed.count {
                let g = Int(composed.indices[i])
                guard g < rest.count, rest.objectIds[g] != 0 else { continue }
                firstMember = firstMember ?? g
                let byHand = rest[g].state(at: t).position
                let dx = Double(composed.centers[i * 3] - byHand.x)
                let dy = Double(composed.centers[i * 3 + 1] - byHand.y)
                let dz = Double(composed.centers[i * 3 + 2] - byHand.z)
                if (dx * dx + dy * dy + dz * dz).squareRoot() > 1e-4 { return }
            }
        }
        if let g = firstMember {
            throw Failure.trackNotComposed(t: times[times.count - 1], gaussian: g)
        }
    }

    static func truncationRecovery(path: String, wholeCount: Int) throws {
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        guard bytes.count >= 16 else { return }

        // Cut before the trailing magic. Everything the file said is still in it, so nothing
        // may be lost: a reader that needs the trailing magic to finish is a reader that
        // cannot read a file that is still being written.
        let tail = try decodeCut(Array(bytes.dropLast(8)))
        guard tail.truncated else {
            throw Failure.notReportedTruncated(what: "a file cut before its trailing magic")
        }
        guard tail.count == wholeCount else {
            throw Failure.lostGaussians(
                what: "cutting the trailing magic", got: tail.count, expected: wholeCount)
        }

        // Cut in the middle. What survives is whatever preceded the cut — never more than the
        // whole file held — and it is still reported as cut.
        if wholeCount > 1 {
            let half = try decodeCut(Array(bytes.prefix(bytes.count / 2)))
            guard half.truncated else {
                throw Failure.notReportedTruncated(what: "half a file")
            }
            guard half.count <= wholeCount else {
                throw Failure.gainedGaussians(what: "half a file", got: half.count, whole: wholeCount)
            }
        }
    }

    private static func decodeCut(_ bytes: [UInt8]) throws -> (count: Int, truncated: Bool) {
        // Sequential: an indexed read of a file whose index was cut off is a different
        // question, and the front-to-back path is the one that has to survive this.
        let reader = try SceneReader(InMemoryReader(bytes), path: .streamed)
        let gaussians = try reader.allGaussians()
        return (gaussians.count, reader.scene.isTruncated)
    }

    // MARK: - SH band range-skipping

    /// Assert that capping spherical-harmonic bands actually moves fewer bytes.
    ///
    /// Measured at the transport, because that is the whole feature: bands each have their own
    /// byte range in the chunk index, and a reader that has decided to evaluate fewer of them
    /// should never fetch the rest. A decoder can evaluate the right bands and still transfer
    /// all of them, and no decoded value would ever show it.
    ///
    /// The assertion is on the byte **count**, not on the call succeeding. A cache that answers
    /// a narrow cap from a wider entry returns the wider byte count while looking perfectly
    /// healthy, which is exactly the shape of bug this is here to catch.
    static func bandRangeSkipping(_ reader: SceneReader) throws {
        let degree = reader.scene.header.shDegree
        for chunk in reader.scene.chunkIntervals.indices {
            var previous: UInt64 = 0
            for cap in 0...max(degree, 0) {
                let bytes = reader.bytesForChunk(chunk, options: DecodeOptions(bandCap: cap))
                guard bytes > 0 else { throw Failure.noBytesMoved(chunk: chunk, cap: cap) }
                if cap > 0, bytes < previous {
                    throw Failure.capMovedMoreThanWider(
                        chunk: chunk, narrow: cap, narrowBytes: bytes, wide: cap - 1,
                        wideBytes: previous)
                }
                previous = bytes
            }
            // With harmonics present, capping them away must cost strictly less than carrying
            // them. Without harmonics there is nothing to skip and nothing to assert.
            if degree > 0 {
                let capped = reader.bytesForChunk(chunk, options: DecodeOptions(bandCap: 0))
                let whole = reader.bytesForChunk(chunk, options: DecodeOptions(bandCap: degree))
                guard capped < whole else {
                    throw Failure.capMovedNothingLess(chunk: chunk, bytes: capped, degree: degree)
                }
            }
        }
    }
}
