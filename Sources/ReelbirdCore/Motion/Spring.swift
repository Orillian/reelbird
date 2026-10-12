import Foundation

/// Easing and spring helpers shared by the cursor and camera paths. Pure and deterministic.
public enum Spring {
    /// Normalised critically damped spring easing: 0 → 1 over `t` in 0...1, zero velocity at the start,
    /// settled at the end. `omegaT` sets how much of the curve is the fast start.
    ///
    /// Peak speed comes at `1/omegaT` of the way through (14% at the default), which reads as a jolt on
    /// large camera moves; the camera uses `glide` instead.
    public static func ease(_ t: Double, omegaT: Double = 7) -> Double {
        let u = min(1, max(0, t))
        if u >= 1 { return 1 }
        let x = omegaT * u
        let end = 1 - (1 + omegaT) * exp(-omegaT)
        return (1 - (1 + x) * exp(-x)) / end
    }

    /// The camera's easing: `smootherstep(t^0.72)`.
    ///
    /// Chosen so a zoom never "snaps": velocity *and* acceleration start at zero (speed grows like t^1.16, so
    /// the first frames barely move), speed peaks a third of the way in (1.81× the average), and the landing
    /// is long and polynomial, so the camera comes fully to rest with zero velocity and acceleration instead
    /// of creeping on an exponential tail. Compared with `ease` (peak at 14%, 3.6× the average speed at the
    /// peak) this halves the peak angular speed of a zoom for the same duration.
    public static func glide(_ t: Double) -> Double {
        let u = min(1, max(0, t))
        let v = pow(u, 0.72)
        return v * v * v * (v * (v * 6 - 15) + 10)
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
    ///
    /// `0.9 + 0.5·ln(ratio)`: 1.0 s for 1.25×, 1.2 s for 1.8×, 1.45 s for 3×. With `glide` that keeps the
    /// peak zoom speed of the default 1.8× zoom under 0.9 ln-units per second (the old 0.6 + 0.55·ln with a
    /// fast-start spring peaked at 1.8, which viewers describe as "dizzying").
    public static func zoomDuration(from a: Double, to b: Double) -> Double {
        let ratio = max(a, b) / max(1e-6, min(a, b))
        return 0.9 + 0.5 * log(max(1, ratio))
    }
}

/// Clamps a viewport centre so a viewport of `1/scale` stays inside the unit frame.
@inline(__always)
public func clampCenter(_ c: NormPoint, scale: Double) -> NormPoint {
    let half = 0.5 / max(1, scale)
    return NormPoint(x: min(1 - half, max(half, c.x)), y: min(1 - half, max(half, c.y)))
}

/// Clamps a viewport centre for a view whose size at zoom 1 is `base` (normalized; `(1, 1)` = the whole
/// frame, smaller when the output crops the source, e.g. a 9:16 export of a landscape screen).
@inline(__always)
public func clampCenter(_ c: NormPoint, scale: Double, base: SIMD2<Double>) -> NormPoint {
    let s = max(1, scale)
    let hx = min(0.5, 0.5 * base.x / s), hy = min(0.5, 0.5 * base.y / s)
    return NormPoint(x: min(1 - hx, max(hx, c.x)), y: min(1 - hy, max(hy, c.y)))
}
