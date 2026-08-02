// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

extension GaussianState {

    /// The gaussians of one chunk that are live at `t`, by §3's rule in full: inside the
    /// half-open validity window, and marginal at or above the file's cutoff.
    ///
    /// Positions come back as decoded rest positions. Moving and fading them to `t` is
    /// ``Gaussian/state(at:)``, kept separate because a consumer that wants the whole set
    /// at once should not pay for a copy it may not want.
    public func live(at t: Double, cutoff: Double) -> GaussianState {
        var kept: [Int] = []
        kept.reserveCapacity(count)
        for i in 0..<count where Self.isLive(self, i, t, cutoff) {
            kept.append(i)
        }
        if kept.count == count { return self }
        return gather(kept)
    }

    /// The §3 test, without materializing a `Gaussian` per candidate: this runs once per
    /// gaussian per seek, and the struct copy is the whole cost at that scale.
    private static func isLive(_ g: GaussianState, _ i: Int, _ t: Double, _ cutoff: Double) -> Bool {
        guard t >= Double(g.winLo[i]), t < Double(g.winHi[i]) else { return false }
        let sigma = g.sigmaT[i]
        if sigma.isInfinite { return true }
        let z = (t - Double(g.muT[i])) / Double(sigma)
        return _exp(-0.5 * z * z) >= cutoff
    }

    /// Copy out the gaussians at `indices`, preserving the structure-of-arrays layout.
    func gather(_ indices: [Int]) -> GaussianState {
        let n = indices.count
        let shWidth = shCoefficientsPerComponent * 3
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
        var objectIds = [UInt32]()
        positions.reserveCapacity(n * 3)
        scales.reserveCapacity(n * 3)
        rotations.reserveCapacity(n * 4)
        colors.reserveCapacity(n * 4)
        motions.reserveCapacity(n * 3)
        muT.reserveCapacity(n)
        sigmaT.reserveCapacity(n)
        winLo.reserveCapacity(n)
        winHi.reserveCapacity(n)
        sh.reserveCapacity(n * shWidth)
        objectIds.reserveCapacity(self.objectIds.isEmpty ? 0 : n)

        for i in indices {
            positions.append(contentsOf: self.positions[i * 3..<(i * 3 + 3)])
            scales.append(contentsOf: self.scales[i * 3..<(i * 3 + 3)])
            rotations.append(contentsOf: self.rotations[i * 4..<(i * 4 + 4)])
            colors.append(contentsOf: self.colors[i * 4..<(i * 4 + 4)])
            motions.append(contentsOf: self.motions[i * 3..<(i * 3 + 3)])
            muT.append(self.muT[i])
            sigmaT.append(self.sigmaT[i])
            winLo.append(self.winLo[i])
            winHi.append(self.winHi[i])
            if shWidth > 0 {
                sh.append(contentsOf: self.sh[i * shWidth..<(i * shWidth + shWidth)])
            }
            // Subset rather than carry the full array: membership is per gaussian, so a
            // filtered state whose ids still index the unfiltered rows would mislabel
            // every gaussian after the first one dropped.
            if !self.objectIds.isEmpty {
                objectIds.append(self.objectIds[i])
            }
        }
        return GaussianState(
            count: n, positions: positions, scales: scales, rotations: rotations, colors: colors,
            motions: motions, muT: muT, sigmaT: sigmaT, winLo: winLo, winHi: winHi, shDegree: shDegree,
            sh: sh,
            objectIds: objectIds
        )
    }

    /// Membership across parts, padded so it stays as long as the gaussians it labels.
    ///
    /// A chunk may omit the `object_id` stream while another carries it — §6.6 makes the
    /// stream optional per chunk, and the core reads an omitted one as background for that
    /// chunk alone. Concatenating with a plain `flatMap` would drop those rows instead of
    /// standing in for them, leaving a non-empty array shorter than `count`: every row
    /// after the gap mislabelled, and an index past the end for the last of them. `0` is
    /// background, so padding says exactly what the absent stream meant.
    private static func joinedMembership(_ parts: [GaussianState]) -> [UInt32] {
        guard parts.contains(where: { !$0.objectIds.isEmpty }) else { return [] }
        var joined = [UInt32]()
        joined.reserveCapacity(parts.reduce(0) { $0 + $1.count })
        for part in parts {
            if part.objectIds.isEmpty {
                joined.append(contentsOf: repeatElement(0, count: part.count))
            } else {
                joined.append(contentsOf: part.objectIds)
            }
        }
        return joined
    }

    /// Concatenate states that agree on spherical-harmonic degree — which every state from
    /// one file does, since a scene declares one degree in its Header.
    public static func concatenated(_ parts: [GaussianState]) -> GaussianState {
        guard let first = parts.first else { return .empty }
        return GaussianState(
            count: parts.reduce(0) { $0 + $1.count },
            positions: parts.flatMap(\.positions),
            scales: parts.flatMap(\.scales),
            rotations: parts.flatMap(\.rotations),
            colors: parts.flatMap(\.colors),
            motions: parts.flatMap(\.motions),
            muT: parts.flatMap(\.muT),
            sigmaT: parts.flatMap(\.sigmaT),
            winLo: parts.flatMap(\.winLo),
            winHi: parts.flatMap(\.winHi),
            shDegree: first.shDegree,
            sh: parts.flatMap(\.sh),
            objectIds: joinedMembership(parts))
    }
}
