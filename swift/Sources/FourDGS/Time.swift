// Copyright 2026 Avala AI
// SPDX-License-Identifier: Apache-2.0

/// Reconstructing a gaussian's state at an instant on the scene clock. §3.
///
/// This is where decoding ends. The format is renderer-agnostic and so is this file: it
/// says what a gaussian *is* at time `t`, and nothing about how anything draws it.
///
/// The arithmetic is done in `Double` even though the stored fields are `Float`, because
/// the scene clock is `f64` and `t - muT` in `Float` loses resolution well before the end
/// of a long scene — a 0.5 ms `sigmaT` an hour in is exactly the case the temporal model
/// exists to express.

extension Gaussian {

    /// The soft temporal weight at `t`: `1` for a gaussian that never fades, otherwise
    /// `exp(-0.5 * ((t - muT) / sigmaT)²)`.
    ///
    /// This is the marginal alone. It says nothing about the validity window, which is a
    /// separate and harder gate — see ``isLive(at:cutoff:)``.
    public func marginal(at t: Double) -> Double {
        if sigmaT.isInfinite { return 1 }
        let z = (t - Double(muT)) / Double(sigmaT)
        return _exp(-0.5 * z * z)
    }

    /// The gaussian's centre at `t`: `position + motion * (t - muT)`.
    public func center(at t: Double) -> Vector3 {
        let dt = Float(t - Double(muT))
        return position + motion * dt
    }

    /// Opacity at `t`: the stored alpha scaled by the marginal.
    public func opacity(at t: Double) -> Float {
        Float(Double(color.w) * marginal(at: t))
    }

    /// Whether `t` falls inside the half-open validity window `[winLo, winHi)`.
    ///
    /// The validity window is the format's only hard temporal gate. Outside it a gaussian
    /// does not exist at that time, whatever its marginal — it is not faded, it is absent.
    public func isWithinWindow(at t: Double) -> Bool {
        t >= Double(winLo) && t < Double(winHi)
    }

    /// §3's whole visibility rule: inside the window, and marginal at or above the file's
    /// cutoff.
    ///
    /// Pass the cutoff from the file's own ``Header``, not the 0.05 default. A file that
    /// declares a different threshold means it.
    public func isLive(at t: Double, cutoff: Double) -> Bool {
        isWithinWindow(at: t) && marginal(at: t) >= cutoff
    }

    /// The gaussian as it stands at `t`: centre moved, opacity scaled, everything else
    /// unchanged. This is the state the SDK's job ends at.
    public func state(at t: Double) -> Gaussian {
        var moved = self
        moved.position = center(at: t)
        moved.color.w = opacity(at: t)
        return moved
    }
}

extension Header {
    /// `K = sqrt(-2 · ln(cutoff))`, the constant §6.3's per-gaussian velocity precision is
    /// derived from.
    ///
    /// It is a property of **this file's** cutoff. A decoder that substitutes the constant
    /// for the default decodes different velocities than the encoder wrote, for any file
    /// that declares a different threshold, and the file gives it no way to notice.
    public var lifetimeConstantK: Double {
        _sqrt(-2 * _log(cutoff))
    }
}

// MARK: - Maths

// The three functions this file needs, taken from the platform's libm. Importing them by
// name rather than pulling in Foundation keeps the core's dependency list at zero.
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

@inline(__always) func _exp(_ x: Double) -> Double { exp(x) }
@inline(__always) func _log(_ x: Double) -> Double { log(x) }
@inline(__always) func _sqrt(_ x: Double) -> Double { x.squareRoot() }
