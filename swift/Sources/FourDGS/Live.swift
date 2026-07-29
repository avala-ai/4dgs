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

    /// The live gaussians across several chunks, concatenated.
    ///
    /// The chunks of an instant are independent, so this is a concatenation and not a
    /// merge. Order is not part of the contract in either direction.
    public static func live(in chunks: [DecodedChunk], at t: Double, cutoff: Double) -> GaussianState {
        let parts = chunks.map { $0.gaussians.live(at: t, cutoff: cutoff) }.filter { $0.count > 0 }
        if parts.isEmpty { return .empty }
        if parts.count == 1 { return parts[0] }
        return concatenated(parts)
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
        }
        return GaussianState(
            count: n, positions: positions, scales: scales, rotations: rotations, colors: colors,
            motions: motions, muT: muT, sigmaT: sigmaT, winLo: winLo, winHi: winHi, shDegree: shDegree, sh: sh)
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
            sh: parts.flatMap(\.sh))
    }
}
