// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FourDGS

/// The two read paths the suite tests, driven the way every other language's runners are:
/// a subprocess, given a path, printing canonical JSON to stdout.
///
/// **Neither is complete, and both say so by failing.** The canonical summary covers what a
/// file says, not only its gaussians — the metadata, attachments, camera, statistics and
/// summary offsets, plus whether the Footer's CRC verified. The C ABI has no accessor for
/// any of that yet, so a runner that printed a summary now would be printing empty arrays
/// where the file has records, and the suite would either fail confusingly or, worse,
/// pass on a variant that happens to carry none. Refusing up front is the honest state, and
/// the conformance job stays disabled until it changes.
///
/// A runner is not the SDK. It materializes every gaussian so it can take the content order
/// the summary is defined in, which is exactly what the SDK itself must never do.
public enum Runner {

    public enum Mode: String {
        case streamed
        case indexed
    }

    public static func main(_ mode: Mode) -> Never {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: \(arguments[0]) <file.4dgs>\n".utf8))
            exit(2)
        }
        do {
            let json = try summarize(path: arguments[1], mode: mode)
            print(json.serialized())
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    static func summarize(path: String, mode: Mode) throws -> JSON {
        let reader = try SceneReader(path: path)
        // The gaussians and the header are reachable; the rest of the summary is not.
        _ = try reader.allGaussians()
        guard reader.scene.recordsAvailable else {
            throw RunnerGap.recordsUnreachable(mode: mode)
        }
        return Summary.build(
            scene: reader.scene,
            gaussians: try reader.allGaussians(),
            chunkIntervals: reader.scene.chunkIntervals.map { ($0.lowerBound, $0.upperBound) },
            summaryChecksumVerified: reader.scene.summaryChecksumVerified)
    }
}

/// What the runner cannot do yet, named rather than papered over.
enum RunnerGap: Error, CustomStringConvertible {
    case recordsUnreachable(mode: Runner.Mode)

    var description: String {
        switch self {
        case .recordsUnreachable(let mode):
            return """
                the \(mode.rawValue) runner decoded the gaussians but cannot emit a canonical summary: \
                the C ABI has no accessor for the metadata, attachment, camera, statistics or \
                summary-offset records, nor for the Footer's summary CRC, and a summary that omitted \
                them would claim the file carries none
                """
        }
    }
}
