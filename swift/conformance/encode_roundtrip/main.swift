// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

// Conformance runner: encode.
//
// Decode a variant, re-encode the gaussians it yields, and write the result. The gate around
// this (tests/conformance/encode_roundtrip.py) re-encodes the same variant with the Rust
// reference and requires the Python decoder to read both files identically — which, since
// Swift reaches the same Rust encoder through the C ABI, proves the binding wired the gaussians
// and options through correctly rather than that a second encoder agrees.
//
// The option preset is the reference's `gaussians_only_options`, reproduced here field for
// field. A drift between them is what the gate exists to catch, so it lives in both places on
// purpose.
//
// Usage: encode_roundtrip <in.4dgs> <out.4dgs> [sh-bit-depths]

import FourDGS
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

// A comma-separated list of per-band bit depths, band 1 first. The gate resolves ladder names
// to a list before handing them here, so every language parses the same thing.
func parseDepths(_ spec: String) -> [UInt8] {
    spec.split(separator: ",").map { part in
        guard let value = Int(part.trimmingCharacters(in: .whitespaces)), value >= 0, value <= 255 else {
            fail("\(spec): not a comma-separated list of bit depths")
        }
        return UInt8(value)
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 3 || arguments.count == 4 else {
    FileHandle.standardError.write(
        Data("usage: encode_roundtrip <in.4dgs> <out.4dgs> [sh-bit-depths]\n".utf8))
    exit(2)
}
let input = arguments[1]
let output = arguments[2]
let depths = arguments.count == 4 ? parseDepths(arguments[3]) : []

do {
    let reader = try SceneReader(path: input, readPath: .streamed)
    let gaussians = try reader.allGaussians(options: DecodeOptions(bandCap: 3))

    // The gaussians-only preset, matching rust/conformance/src/bin/encode_gaussians.rs: a small
    // chunk threshold so the corpus scenes exercise the chunk tree, the whole summary written,
    // the profile and attributes carried through, the library left at the encoder's default.
    var options = WriteOptions()
    options.cutoff = reader.scene.header.cutoff
    options.maxDepth = 4
    options.minChunkGaussians = 8
    options.writeIndex = true
    options.writeStatistics = true
    options.writeSummaryOffsets = true
    options.writeCrc = true
    options.shBands = 3
    options.shBitDepths = depths
    options.profile = reader.scene.header.profile
    options.attributes = reader.scene.header.attributes

    let bytes = try SceneWriter.encode(
        gaussians, durationSec: reader.scene.header.durationSec, options: options)
    try Data(bytes).write(to: URL(fileURLWithPath: output))
    print("\(gaussians.count) gaussians, \(bytes.count) bytes")
} catch {
    fail("\(error)")
}
