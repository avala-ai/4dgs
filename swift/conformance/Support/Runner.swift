// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FourDGS

/// The two read paths the suite tests, driven the way every other language's runners are:
/// a subprocess, given a path, printing canonical JSON to stdout.
///
/// The two are forced apart rather than left to the core's choice. They exist to be able to
/// disagree — a streamed decode and an indexed one reach the same gaussians by different
/// routes — and a suite that ran whichever path the core happened to pick would run one of
/// them twice and count it as two passes.
///
/// A runner is not the SDK. It materializes every gaussian so it can take the content order
/// the summary is defined in, which is exactly what the SDK itself must never do.
public enum Runner {

    public enum Mode: String {
        case streamed
        case indexed

        var readPath: SceneReader.ReadPath {
            switch self {
            case .streamed: return .streamed
            case .indexed: return .indexed
            }
        }
    }

    public static func main(_ mode: Mode) -> Never {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: \(arguments[0]) <file.4dgs>\n".utf8))
            exit(2)
        }
        do {
            let path = arguments[1]
            // keyframe-delta is a whole-file temporal model an opened scene refuses, so it is
            // dispatched on before opening. The core computes the states JSON and it is
            // printed verbatim — byte-identical to every other SDK's, which is the whole
            // point of computing it once in Rust rather than in each binding.
            let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
            if try peekTemporalModel(bytes) == "keyframe-delta" {
                print(try keyframeDeltaStatesJson(bytes, indexed: mode == .indexed))
                exit(0)
            }
            let json = try summarize(path: path, mode: mode)
            print(json.serialized())
            exit(0)
        } catch let error as FourDGSError {
            // Only an error the refusal table names is an answer. Anything else is a failed
            // invocation and takes the same exit as a runner fault below, because a runner
            // that answered it with an empty identifier would be claiming a valid answer for
            // a failure no expectation can check. See `refusal(_:)`.
            guard let answer = refusal(error) else {
                FileHandle.standardError.write(Data("\(arguments[1]): \(error)\n".utf8))
                exit(1)
            }
            print(answer.serialized())
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    /// The canonical answer for a file this reader refused, or `nil` when it is not one.
    ///
    /// A refusal is a result, not a crash: it goes to stdout and the process exits 0, so the
    /// harness diffs it against the expectation like any other answer. Exiting non-zero
    /// would make "refused the right file for the right reason" and "fell over somewhere in
    /// the same file" the same observation, and telling those apart is the entire purpose of
    /// the invalid corpus — a decoder must not be able to pass by crashing in the right
    /// place.
    ///
    /// An error the refusal table does not name is not that result, and `nil` says so. The
    /// caller turns it into a failed invocation — a diagnosis on stderr, a non-zero exit —
    /// which is the split the Rust and C++ runners already keep through the same optional.
    /// Printing the missing identifier as `""` instead exits 0, and so claims a valid answer
    /// for something the format does not define an identifier for: the harness can no longer
    /// tell "refused for a reason nobody named" from "refused for the wrong reason", and
    /// `run.py --update` — which writes what a runner prints without parsing it — could
    /// commit the empty identifier as the expectation every other SDK is scored against.
    static func refusal(_ error: FourDGSError) -> JSON? {
        guard let code = error.refusalCode else { return nil }
        return .object(["refused": .string(code.rawValue)])
    }

    static func summarize(path: String, mode: Mode) throws -> JSON {
        let reader = try SceneReader(path: path, readPath: mode.readPath)
        var scene = reader.scene
        // Canonical JSON proves payload bytes too, but normal SDK opening deliberately
        // leaves them deferred. The conformance runner opts in, one bounded source at a
        // time, because materializing the whole file is runner-only behaviour.
        for index in scene.audioSources.indices {
            scene.audioSources[index].data = try reader.audioSourceData(
                index, length: scene.audioSources[index].dataSize)
        }

        // The indexed runner reads chunk by chunk through the index, so the path being
        // measured is the one this runner claims to measure. The streamed runner takes the
        // whole working set, which is what a front-to-back decode produces.
        let gaussians: GaussianState
        switch mode {
        case .streamed:
            gaussians = try reader.allGaussians()
        case .indexed:
            var parts: [GaussianState] = []
            parts.reserveCapacity(scene.chunkIntervals.count)
            for i in scene.chunkIntervals.indices {
                parts.append(try reader.chunk(i))
            }
            gaussians = GaussianState.concatenated(parts)
        }

        // The two rows the canonical JSON cannot carry, each on the runner that owns it: a cut
        // file must be read front to back, and a band cap is only meaningful where there is an
        // index to skip ranges in.
        switch mode {
        case .streamed:
            try ExtraChecks.truncationRecovery(path: path, wholeCount: gaussians.count)
        case .indexed:
            try ExtraChecks.bandRangeSkipping(reader)
        }

        // Provenance is computed in the Rust core (posesAt / sensorPosesAt included) so
        // this binding cannot drift from the reference on slerp. Empty means omit the key.
        let provenanceJson = try reader.provenanceJson()
        // The object layer likewise: the core composes base-then-track and samples each
        // pose, so C++, Swift and Rust cannot disagree about composition order.
        let objectsJson = try reader.objectsJson()
        let objectStatesJson = try reader.objectStatesJson()

        // The row the canonical JSON cannot carry for this family: that *this binding's*
        // reconstruction surfaces the composition, not merely that the core computed it for
        // the summary. Runs after the JSON calls because those load the whole scene, which
        // would otherwise disturb the band-range check above.
        let duration = scene.header.durationSec
        // Read off the summary the core just produced rather than re-reading the records:
        // an empty `tracks` array means membership without motion, which composes to the
        // identity and can prove nothing either way.
        let layerHasTrack = !objectsJson.isEmpty && !objectsJson.contains("\"tracks\":[]")
        try ExtraChecks.objectTracksAreComposed(
            reader, at: [0.0, duration * 0.5, duration * 0.75], layerHasTrack: layerHasTrack)

        return Summary.build(
            scene: scene,
            gaussians: gaussians,
            chunkIntervals: scene.chunkIntervals.map { ($0.lowerBound, $0.upperBound) },
            summaryChecksumVerified: scene.summaryChecksumVerified,
            provenanceJson: provenanceJson,
            objectsJson: objectsJson,
            objectStatesJson: objectStatesJson)
    }
}
