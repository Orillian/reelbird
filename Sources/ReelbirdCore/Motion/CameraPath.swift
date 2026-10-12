import Foundation

/// The zoom camera over time: magnification and the source point at the centre of the view.
///
/// Built once from zoom regions and the smoothed cursor into a fixed-rate table, so playback, seeking and
/// export all read identical values.
///
/// Motion rules (the defaults are tuned against "dizzying" complaints about other recorders):
/// - Zooming in or out of a region takes `Spring.zoomDuration` (1.2 s for the default 1.8×) on the `glide`
///   curve, which starts imperceptibly and lands softly. Scale is interpolated in log space about the one
///   point that stays put on screen, so the content never drifts sideways while it grows.
/// - Moving from one region straight to another follows the van Wijk–Nuij optimal zoom-and-pan path
///   (ρ = 1.3): a short hop is a plain pan, a long one eases out a little mid-way so the content never
///   whips across the screen. Its duration grows with the path's perceptual length, capped at 1.8 s.
/// - Regions without a focus follow the cursor with a dead zone (the middle half of the view) and a
///   critically damped spring; so does the un-zoomed view when the output crops the source (a 9:16 export
///   of a landscape screen).
/// - The view always stays inside the frame.
public struct CameraPath: Sendable {
    public static let sampleRate: Double = 120
    /// van Wijk–Nuij ρ: how readily long pans zoom out. 1.3 is a little calmer than the paper's 1.42.
    static let rho = 1.3

    /// Sanitised regions (sorted, clamped, non-overlapping) the path was built from.
    public let regions: [ZoomRegion]
    public let duration: Double
    /// The view's size at zoom 1 (normalized; `(1, 1)` unless the output crops the source).
    public let base: SIMD2<Double>
    /// (ln scale, centre x, centre y) at `sampleRate`.
    let table: [SIMD3<Float>]

    enum State: Equatable { case wide, region(Int) }
    struct Segment { var t0: Double; var t1: Double; var from: State; var to: State }

    /// The camera for an output that shows the whole source at zoom 1 (16:10 source assumed for pan metrics).
    public init(regions: [ZoomRegion], cursor: CursorPath, duration: Double) {
        self.init(regions: regions, cursor: cursor, duration: duration, aspect: 16.0 / 10.0, base: SIMD2(1, 1))
    }

    /// The camera for a source of `aspect` (width / height) whose view at zoom 1 covers `base` of the frame.
    public init(regions: [ZoomRegion], cursor: CursorPath, duration: Double, aspect: Double, base: SIMD2<Double>) {
        let duration = max(0, duration.isFinite ? duration : 0)
        let aspect = aspect.isFinite && aspect > 0 ? aspect : 16.0 / 10.0
        let base = SIMD2(min(1, max(0.05, base.x.isFinite ? base.x : 1)), min(1, max(0.05, base.y.isFinite ? base.y : 1)))
        self.duration = duration
        self.base = base
        let crops = base.x < 0.999 || base.y < 0.999
        // A cropped view already magnifies the screen, so soften zooms there: scale × √(crop). The default
        // 1.8× zoom in a 9:16 window that shows half the screen becomes 1.28×, framing about what a 2.5×
        // zoom would on the full frame rather than a claustrophobic 3.5×.
        let soften = crops ? min(base.x, base.y).squareRoot() : 1
        // Sanitise: clamp, drop no-ops, sort, split overlaps at the midpoint.
        var rs = regions.compactMap { r -> ZoomRegion? in
            var r = r
            r.range = TimeRange(start: max(0, r.range.start), end: min(duration, r.range.end))
            r.scale = min(8, max(1, r.scale.isFinite ? r.scale * soften : 1))
            guard r.range.duration > 0.05, r.scale > 1.001 else { return nil }
            return r
        }.sorted { ($0.range.start, $0.id) < ($1.range.start, $1.id) }
        var i = 1
        while i < rs.count {
            if rs[i].range.start < rs[i - 1].range.end {
                let mid = max(rs[i - 1].range.start, min(rs[i].range.end, (rs[i].range.start + rs[i - 1].range.end) / 2))
                rs[i - 1].range.end = mid
                rs[i].range.start = mid
                if rs[i - 1].range.duration <= 0.05 { rs.remove(at: i - 1); continue }
                if rs[i].range.duration <= 0.05 { rs.remove(at: i); continue }
            }
            i += 1
        }
        self.regions = rs

        // The view's linear size in source-height units at a given scale, for van Wijk distances.
        let viewUnit = max(base.x * aspect, base.y)

        // Transitions in time order.
        var transitions: [Segment] = []
        for (k, r) in rs.enumerated() {
            let d = min(Spring.zoomDuration(from: 1, to: r.scale), max(0.3, r.range.duration))
            let inSeg = Segment(t0: r.range.start - d / 2, t1: r.range.start + d / 2, from: .wide, to: .region(k))
            if let last = transitions.last, last.to == .wide, case .region(let p) = last.from, p == k - 1,
               inSeg.t0 < last.t1 + 0.3 {
                // The previous region's zoom-out has not finished before this zoom-in starts: go directly.
                transitions.removeLast()
                let prev = rs[p]
                let a = prev.focus ?? .center, b = r.focus ?? .center
                let dist = hypot((b.x - a.x) * aspect, b.y - a.y)
                let S = Self.vanWijkLength(w0: viewUnit / prev.scale, w1: viewUnit / r.scale, u1: dist)
                let dd = min(1.8, max(Spring.zoomDuration(from: prev.scale, to: r.scale), 0.6 + 0.5 * S))
                let mid = (prev.range.end + r.range.start) / 2
                transitions.append(Segment(t0: mid - dd / 2, t1: mid + dd / 2, from: .region(p), to: .region(k)))
            } else {
                transitions.append(inSeg)
            }
            transitions.append(Segment(t0: r.range.end - d / 2, t1: r.range.end + d / 2, from: .region(k), to: .wide))
        }
        // Keep transitions from overlapping: meet in the middle of any overlap.
        for j in transitions.indices.dropFirst() where transitions[j].t0 < transitions[j - 1].t1 {
            let mid = (transitions[j].t0 + transitions[j - 1].t1) / 2
            transitions[j - 1].t1 = max(transitions[j - 1].t0 + 1e-3, mid)
            transitions[j].t0 = min(transitions[j].t1 - 1e-3, mid)
        }

        // The follower: an unclamped point that tracks the cursor with a dead zone and a critically damped
        // spring, for focus-less regions and (when cropping) the un-zoomed view. It runs continuously so
        // there is never a jump when a following view begins.
        let rate = Self.sampleRate
        let dt = 1 / rate
        let count = max(1, Int((duration * rate).rounded(.up)) + 1)
        var out = [SIMD3<Float>](repeating: SIMD3(0, 0.5, 0.5), count: count)
        let followOmega = 4.0
        let followDecay = exp(-followOmega * dt)
        let c0 = cursor.position(at: 0) ?? .center
        var fx = min(1, max(0, c0.x)), fy = min(1, max(0, c0.y)), fvx = 0.0, fvy = 0.0
        var tx = fx, ty = fy

        func stepFollow(_ t: Double, scale s: Double) {
            let cur = cursor.position(at: t) ?? NormPoint(x: tx, y: ty)
            let cx = min(1, max(0, cur.x)), cy = min(1, max(0, cur.y))
            // Dead zone: the middle half of a zoomed view; the middle 36% of an un-zoomed cropped window,
            // whose narrow view otherwise parks off to one side of the action.
            let k = s <= 1.001 ? 0.18 : 0.25
            let dx = k * base.x / s, dy = k * base.y / s
            if cx > tx + dx { tx = cx - dx } else if cx < tx - dx { tx = cx + dx }
            if cy > ty + dy { ty = cy - dy } else if cy < ty - dy { ty = cy + dy }
            let tc = clampCenter(NormPoint(x: tx, y: ty), scale: s, base: base)
            Spring.step(x: &fx, v: &fvx, target: tc.x, omega: followOmega, dt: dt, decay: followDecay)
            Spring.step(x: &fy, v: &fvy, target: tc.y, omega: followOmega, dt: dt, decay: followDecay)
        }
        func resolve(_ st: State) -> (s: Double, c: NormPoint) {
            switch st {
            case .wide:
                return crops ? (1, clampCenter(NormPoint(x: fx, y: fy), scale: 1, base: base)) : (1, .center)
            case .region(let k):
                let s = rs[k].scale
                if let f = rs[k].focus { return (s, clampCenter(f, scale: s, base: base)) }
                return (s, clampCenter(NormPoint(x: fx, y: fy), scale: s, base: base))
            }
        }
        func followScale(_ a: State, _ b: State) -> Double {
            for st in [b, a] { if case .region(let k) = st, rs[k].focus == nil { return rs[k].scale } }
            return crops ? 1 : 2
        }

        var seg = 0
        for n in 0..<count {
            let t = Double(n) * dt
            while seg < transitions.count, transitions[seg].t1 <= t { seg += 1 }
            // Current state: inside a transition, or holding the state the last transition reached.
            var from: State, to: State, u = 1.0
            if seg < transitions.count, transitions[seg].t0 <= t {
                from = transitions[seg].from; to = transitions[seg].to
                u = (t - transitions[seg].t0) / (transitions[seg].t1 - transitions[seg].t0)
            } else {
                from = seg > 0 ? transitions[seg - 1].to : .wide
                to = from
            }
            stepFollow(t, scale: followScale(from, to))
            let a = resolve(from), b = resolve(to)
            var s: Double, c: NormPoint
            if case .region = from, case .region = to, from != to {
                (s, c) = Self.vanWijk(a: a, b: b, u: Spring.glide(u), aspect: aspect, viewUnit: viewUnit)
            } else {
                let e = Spring.glide(u)
                let la = log(a.s), lb = log(b.s)
                s = exp(la + (lb - la) * e)
                if abs(lb - la) < 1e-4 {
                    c = NormPoint(x: a.c.x + (b.c.x - a.c.x) * e, y: a.c.y + (b.c.y - a.c.y) * e)
                } else {
                    // Zoom about the fixed point A where (A - c0)·s0 == (A - c1)·s1.
                    let ax = (a.c.x * a.s - b.c.x * b.s) / (a.s - b.s)
                    let ay = (a.c.y * a.s - b.c.y * b.s) / (a.s - b.s)
                    c = NormPoint(x: ax - (ax - a.c.x) * a.s / s, y: ay - (ay - a.c.y) * a.s / s)
                }
            }
            c = clampCenter(c, scale: s, base: base)
            out[n] = SIMD3(Float(log(s)), Float(c.x), Float(c.y))
        }
        table = out
    }

    /// Perceptual length S of the optimal zoom-and-pan path between views of size `w0` and `w1` whose centres
    /// are `u1` apart (all in the same units). van Wijk & Nuij, "Smooth and efficient zooming and panning", 2003.
    static func vanWijkLength(w0: Double, w1: Double, u1: Double) -> Double {
        let r = rho
        if u1 < 1e-6 { return abs(log(w1 / w0)) / r }
        let b0 = (w1 * w1 - w0 * w0 + r * r * r * r * u1 * u1) / (2 * w0 * r * r * u1)
        let b1 = (w1 * w1 - w0 * w0 - r * r * r * r * u1 * u1) / (2 * w1 * r * r * u1)
        let r0 = log(-b0 + (b0 * b0 + 1).squareRoot()), r1 = log(-b1 + (b1 * b1 + 1).squareRoot())
        return (r1 - r0) / r
    }

    /// A point `e` (0...1) of the way along the optimal path from view `a` to view `b`.
    static func vanWijk(a: (s: Double, c: NormPoint), b: (s: Double, c: NormPoint), u e: Double, aspect: Double,
                        viewUnit: Double) -> (Double, NormPoint) {
        let r = rho
        let w0 = viewUnit / a.s, w1 = viewUnit / b.s
        let dx = (b.c.x - a.c.x) * aspect, dy = b.c.y - a.c.y
        let u1 = hypot(dx, dy)
        var w: Double, frac: Double
        if u1 < 1e-6 {
            w = w0 * pow(w1 / w0, e)
            frac = e
        } else {
            let b0 = (w1 * w1 - w0 * w0 + r * r * r * r * u1 * u1) / (2 * w0 * r * r * u1)
            let b1 = (w1 * w1 - w0 * w0 - r * r * r * r * u1 * u1) / (2 * w1 * r * r * u1)
            let r0 = log(-b0 + (b0 * b0 + 1).squareRoot()), r1 = log(-b1 + (b1 * b1 + 1).squareRoot())
            let S = (r1 - r0) / r
            let sp = S * e
            w = w0 * cosh(r0) / cosh(r * sp + r0)
            let u = w0 / (r * r) * (cosh(r0) * tanh(r * sp + r0) - sinh(r0))
            frac = min(1, max(0, u / u1))
            if e >= 1 { w = w1; frac = 1 }
        }
        var s = viewUnit / w
        // Never zoom out past the whole frame; roll off smoothly into 1 instead of clipping.
        let knee = min(1.1, a.s, b.s)
        if s < knee, knee > 1.0001 { s = 1 + (knee - 1) * exp((s - knee) / (knee - 1)) }
        return (s, NormPoint(x: a.c.x + (b.c.x - a.c.x) * frac, y: a.c.y + (b.c.y - a.c.y) * frac))
    }

    /// Magnification (≥ 1) and the source point at the centre of the view at time `t` (source timeline).
    public func transform(at t: Double) -> (scale: Double, center: NormPoint) {
        guard !table.isEmpty else { return (1, .center) }
        let f = t * Self.sampleRate
        let v: SIMD3<Float>
        if !(f > 0) { v = table[0] } else {
            let i = Int(f)
            if i >= table.count - 1 { v = table[table.count - 1] } else {
                v = table[i] + (table[i + 1] - table[i]) * Float(f - Double(i))
            }
        }
        let s = exp(Double(v.x))
        return (s, clampCenter(NormPoint(x: Double(v.y), y: Double(v.z)), scale: s, base: base))
    }

    /// The visible source rectangle at time `t`.
    public func viewport(at t: Double) -> NormRect {
        let (s, c) = transform(at: t)
        let w = base.x / s, h = base.y / s
        return NormRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
    }
}
