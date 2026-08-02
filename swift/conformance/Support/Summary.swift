// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FourDGS

/// The statement every implementation must agree on for a variant.
///
/// A restatement in Swift of `tests/conformance/canonical.py`. Where the two could drift,
/// the Python one is the definition and this one is wrong.
public enum Summary {

    /// How many gaussians appear in full. The aggregates cover the rest, so a decoder
    /// cannot pass by getting a prefix right.
    static let sample = 16
    /// How many camera keyframes appear in full, so a long trajectory cannot bloat a
    /// summary.
    static let cameraKeyframes = 4
    static let audioKeyframes = 4

    public static func build(
        scene: Scene,
        gaussians: GaussianState,
        chunkIntervals: [(Double, Double)],
        summaryChecksumVerified: Bool?,
        provenanceJson: String = "",
        objectsJson: String = "",
        objectStatesJson: String = ""
    ) -> JSON {
        let order = stableOrder(gaussians)
        let sampled = Array(order.prefix(sample))

        var positionSum = [0.0, 0.0, 0.0]
        var opacitySum = 0.0
        var neverFades = 0
        var zeroMotion = 0
        // Summed in content order, not index order: two decoders that visit gaussians
        // differently must reach the same total, and floating-point addition is not
        // associative enough to leave that to chance.
        for i in order {
            for k in 0..<3 { positionSum[k] += Double(gaussians.positions[i * 3 + k]) }
            opacitySum += Double(gaussians.colors[i * 4 + 3])
            if !gaussians.sigmaT[i].isFinite { neverFades += 1 }
            let m = gaussians.motions
            if abs(m[i * 3]) + abs(m[i * 3 + 1]) + abs(m[i * 3 + 2]) == 0 { zeroMotion += 1 }
        }

        func rows(_ array: [Float], _ width: Int) -> JSON {
            .array(sampled.map { i in .array((0..<width).map { JSON.number(array[i * width + $0]) }) })
        }
        func column(_ array: [Float]) -> JSON {
            .array(sampled.map { JSON.number(array[$0]) })
        }

        var sampleFields: [String: JSON] = [
            "positions": rows(gaussians.positions, 3),
            "scales": rows(gaussians.scales, 3),
            "rotations": rows(gaussians.rotations, 4),
            "colors": rows(gaussians.colors, 4),
            "motions": rows(gaussians.motions, 3),
            "muT": column(gaussians.muT),
            "sigmaT": column(gaussians.sigmaT),
            "winLo": column(gaussians.winLo),
            "winHi": column(gaussians.winHi),
        ]
        // Membership is an exact label, so it is rendered as an integer string like the
        // counts are, never as a float. The key is absent when the scene carries no
        // `object_id` stream — a different file from one where every gaussian is
        // background, which would carry the key with every entry "0".
        if !gaussians.objectIds.isEmpty {
            sampleFields["objectIds"] = .array(sampled.map { .string(String(gaussians.objectIds[$0])) })
        }

        var fields: [String: JSON] = [
            "gaussianCount": .integer(gaussians.count),
            "durationSec": .number(scene.header.durationSec),
            "cutoff": .number(scene.header.cutoff),
            // The Header's first two fields: readable everywhere, asserted nowhere until now.
            "profile": .string(scene.header.profile),
            "library": .string(scene.header.library),
            "shDegree": .number(String(scene.header.shDegree)),
            "temporalModel": .string(scene.header.temporalModel),
            "hasAudio": .bool(scene.header.hasAudio),
            "audioSources": .array(
                scene.audioSources.sorted { $0.sourceId < $1.sourceId }.map {
                    audioSource($0, sampleTime: scene.header.durationSec / 2)
                }),
            "chunkIntervals": .array(chunkIntervals.map { .array([.number($0.0), .number($0.1)]) }),
            "headerAttributes": jsonMap(scene.header.attributes),
            "metadataRecords": .array(
                scene.metadata.map { .object(["name": .string($0.name), "entries": jsonMap($0.entries)]) }),
            "attachments": .array(
                scene.attachments.map {
                    .object([
                        "name": .string($0.name),
                        "mediaType": .string($0.mediaType),
                        "byteLength": .integer($0.data.count),
                        "crc": .integer(CRC32.compute($0.data)),
                    ])
                }),
            "camera": camera(scene.camera),
            "statistics": statistics(scene.statistics),
            "summaryOffsets": .array(
                scene.summaryOffsets.map {
                    .object([
                        "groupOpcode": .integer($0.groupOpcode),
                        "groupStart": .integer($0.groupStart),
                        "groupLength": .integer($0.groupLength),
                    ])
                }),
            "summaryCrcOk": summaryChecksumVerified.map { JSON.bool($0) } ?? .null,
            "sh": sphericalHarmonics(gaussians, order),
            "sample": .object(sampleFields),
            "aggregate": .object([
                "positionSum": .array(positionSum.map { JSON.number($0) }),
                "opacitySum": .number(opacitySum),
                "neverFadesCount": .integer(neverFades),
                "zeroMotionCount": .integer(zeroMotion),
            ]),
        ]

        // Omitted entirely when the file carries no provenance — not the `audioSources`
        // convention. A file without provenance is a file the record family does not apply to.
        if !provenanceJson.isEmpty {
            fields["provenance"] = .raw(provenanceJson)
        }
        // Same rule for the object layer, and the two members are independent: a file can
        // carry membership with no Object Table, or a table whose objects hold no gaussians.
        if !objectsJson.isEmpty {
            fields["objects"] = .raw(objectsJson)
        }
        if !objectStatesJson.isEmpty {
            fields["states"] = .raw(objectStatesJson)
        }

        return .object(fields)
    }

    // MARK: - Records that are not gaussians
    //
    // Summarized too, because a record that changes nothing here is a record an
    // implementation could ignore entirely and still pass — which is how a feature matrix
    // ends up claiming things the suite never checked.

    private static func audioSource(_ audio: AudioSource, sampleTime: Double) -> JSON {
        let state = audio.state(at: sampleTime)
        return .object([
            "sourceId": .integer(audio.sourceId),
            "name": .string(audio.name),
            "codec": .string(audio.codec),
            "channelLayout": .string(audio.channelLayout),
            "startSec": .number(audio.startSec),
            "durationSec": .number(audio.durationSec),
            "gain": .number(audio.gain),
            "spatial": .bool(audio.spatial),
            "loop": .bool(audio.loop),
            "position": .array(audio.position.map { .number($0) }),
            "rotation": .array(audio.rotation.map { .number($0) }),
            "keyframeCount": .integer(audio.keyframes.count),
            "keyframes": .array(
                audio.keyframes.prefix(audioKeyframes).map {
                    .object([
                        "time": .number($0.time),
                        "position": .array($0.position.map { .number($0) }),
                        "rotation": .array($0.rotation.map { .number($0) }),
                    ])
                }),
            "interpolation": .string(audio.interpolation),
            "stateAtHalf": .object([
                "active": .bool(state.active),
                "localTime": .number(state.localTime),
                "position": .array(state.position.map { .number($0) }),
                "rotation": .array(state.rotation.map { .number($0) }),
                "gain": .number(state.gain),
            ]),
            "byteLength": .integer(audio.data.count),
            "crc": .integer(CRC32.compute(audio.data)),
        ])
    }

    private static func camera(_ camera: Camera?) -> JSON {
        guard let camera else { return .null }
        return .object([
            "fovYDeg": .number(camera.fovYDeg),
            "position": .array(camera.position.map { JSON.number($0) }),
            "target": .array(camera.target.map { JSON.number($0) }),
            "keyframeCount": .integer(camera.keyframes.count),
            "keyframes": .array(
                camera.keyframes.prefix(cameraKeyframes).map {
                    .object([
                        "time": .number($0.time),
                        "position": .array($0.position.map { JSON.number($0) }),
                        "target": .array($0.target.map { JSON.number($0) }),
                    ])
                }),
            "interpolation": .string(camera.interpolation),
            "loop": .bool(camera.loop),
        ])
    }

    private static func statistics(_ statistics: Statistics?) -> JSON {
        guard let statistics else { return .null }
        return .object([
            "gaussianCount": .integer(statistics.gaussianCount),
            "chunkCount": .integer(statistics.chunkCount),
            "durationSec": .number(statistics.durationSec),
            "aabb": .array(statistics.aabb.map { JSON.number($0) }),
        ])
    }

    /// Degree, width and a checksum of the coefficients in content order.
    ///
    /// A digest rather than the coefficients themselves: degree 2 over 512 gaussians is
    /// 12,288 bytes, which would swamp the expectation without proving anything the
    /// checksum does not.
    private static func sphericalHarmonics(_ gaussians: GaussianState, _ order: [Int]) -> JSON {
        let width = gaussians.shCoefficientsPerComponent * 3
        guard gaussians.shDegree > 0, width > 0, !gaussians.sh.isEmpty else { return .null }
        var payload = [UInt8]()
        payload.reserveCapacity(order.count * width)
        for i in order {
            payload.append(contentsOf: gaussians.sh[i * width..<(i * width + width)])
        }
        return .object([
            "degree": .number(String(gaussians.shDegree)),
            "coefficients": .integer(gaussians.shCoefficientsPerComponent),
            "crc": .integer(CRC32.compute(payload)),
        ])
    }

    // MARK: - Content order

    /// Sort gaussians into an order both implementations can reproduce.
    ///
    /// Nothing in the summary may depend on decoded order — an encoder may reorder
    /// gaussians freely, so a summary that depended on it would ask two correct decoders
    /// to disagree. The key is the gaussian's whole decoded state, rounded exactly as the
    /// summary rounds it, with its spherical-harmonic coefficients last. Two gaussians
    /// that tie on all of it are identical in every value the summary emits, so their
    /// relative order cannot change the output.
    static func stableOrder(_ g: GaussianState) -> [Int] {
        let shWidth = g.shCoefficientsPerComponent * 3
        var keys: [(key: [Double], index: Int)] = []
        keys.reserveCapacity(g.count)
        for i in 0..<g.count {
            var row = [Double]()
            row.reserveCapacity(17 + shWidth)
            for k in 0..<3 { row.append(sortable(g.positions[i * 3 + k])) }
            for k in 0..<3 { row.append(sortable(g.scales[i * 3 + k])) }
            for k in 0..<4 { row.append(sortable(g.rotations[i * 4 + k])) }
            for k in 0..<4 { row.append(sortable(g.colors[i * 4 + k])) }
            for k in 0..<3 { row.append(sortable(g.motions[i * 3 + k])) }
            row.append(sortable(g.muT[i]))
            row.append(sortable(g.sigmaT[i]))
            row.append(sortable(g.winLo[i]))
            row.append(sortable(g.winHi[i]))
            if shWidth > 0 {
                for k in 0..<shWidth { row.append(Double(g.sh[i * shWidth + k])) }
            }
            keys.append((row, i))
        }
        // Ties broken by original index. Swift's sort is not stable and Python's is; the
        // tie-break makes the difference invisible rather than relying on it.
        keys.sort { a, b in
            for (x, y) in zip(a.key, b.key) where x != y { return x < y }
            return a.index < b.index
        }
        return keys.map(\.index)
    }

    /// A comparison key: rounded like the summary, with infinity kept as infinity so the
    /// two languages order never-fading gaussians identically.
    private static func sortable(_ value: Float) -> Double {
        let v = Double(value)
        if v.isNaN { return .infinity }
        if v.isInfinite { return v }
        return Double(String(format: "%.6f", v)) ?? v
    }
}
