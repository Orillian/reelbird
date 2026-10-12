import Foundation

/// Critically damped spring helpers shared by the cursor and camera paths. Pure and deterministic.
public enum Spring {
    /// Normalised critically damped spring easing: 0 → 1 over `t` in 0...1, zero velocity at the start,
    /// settled at the end. `omegaT` sets how much of the curve is the fast start (7 ≈ Screen Studio feel).
    public static func ease(_ t: Double, omegaT: Double = 7) -> Double {
        let u = min(1, max(0, t))
        if u >= 1 { return 1 }
        let x = omegaT * u
        let end = 1 - (1 + omegaT) * exp(-omegaT)
        return (1 - (1 + x) * exp(-x)) / end
    }

    /// Exact one-step update of a critically damped spring with natural frequency `omega` chasing a
    /// target held constant over `dt`. Unconditionally stable. `decay` is `exp(-omega * dt)`, passed in
    /// so hot loops compute it once.
    @inline(__always)
    public static func step(x: inout Double, v: inout Double, target: Double, omega: Double, dt: Double, decay: Double) {
        let x0 = x - target
        let k = v + omega * x0
        x = target + (x0 + k * dt) * decay
        v = (v - omega * k * dt) * decay
    }

    /// Zoom transition length in seconds for a change of magnification: deeper zooms take longer.
    public static func zoomDuration(from a: Double, to b: Double) -> Double {
        let ratio = max(a, b) / max(1e-6, min(a, b))
        return 0.6 + 0.55 * log(max(1, ratio))
    }
}

/// Clamps a viewport centre so a viewport of `1/scale` stays inside the unit frame.
@inline(__always)
public func clampCenter(_ c: NormPoint, scale: Double) -> NormPoint {
    let half = 0.5 / max(1, scale)
    return NormPoint(x: min(1 - half, max(half, c.x)), y: min(1 - half, max(half, c.y)))
}
