// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FourDGS

/// The two read paths the suite tests, driven the same way every other language's runners
/// are: a subprocess, given a path, printing canonical JSON to stdout.
///
/// A runner is not the SDK. It materializes every gaussian in the file so it can take the
/// content order the summary is defined in, which is exactly the thing the SDK itself must
/// never do — `run.py` is comparing whole-file statements, and Python's runner does the
/// same. Bounded memory is a property of `StreamedReader`, and it is preserved: the runner
/// accumulates what it has decoded, the reader still holds one chunk at a time.
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
        let source = try FileReader(path: path)
        switch mode {
        case .streamed:
            var reader = try StreamedReader(source)
            var chunks: [DecodedChunk] = []
            while let chunk = try reader.nextChunk() {
                chunks.append(chunk)
            }
            return summary(reader.scene, chunks)
        case .indexed:
            var reader = try IndexedReader(source)
            let chunks = try reader.scene.chunkIndex.map { try reader.chunk($0) }
            return summary(reader.scene, chunks)
        }
    }

    private static func summary(_ scene: Scene, _ chunks: [DecodedChunk]) -> JSON {
        Summary.build(
            scene: scene,
            gaussians: GaussianState.concatenated(chunks.map(\.gaussians)),
            chunkIntervals: chunks.map { ($0.t0, $0.t1) },
            summaryChecksumVerified: scene.summaryChecksumVerified)
    }
}
