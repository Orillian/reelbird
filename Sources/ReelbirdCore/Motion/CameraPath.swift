import Foundation

/// The zoom camera over time: magnification and the source point at the centre of the view.
///
/// Built once from zoom regions and the smoothed cursor into a fixed-rate table, so playback, seeking and
/// export all read identical values. Transitions take `0.6 + 0.55·ln(ratio)` seconds with a critically damped
/// spring easing; scale is interpolated in log space and the view zooms about the one point that stays put
/// on screen, so the focus never drifts. Regions too close to zoom out between them become a pan.
/// Regions without a focus follow the cursor with a dead zone. The view always stays inside the frame.
public struct CameraPath: Sendable {
    public static let sampleRate: Double = 120

    /// Sanitised regions (sorted, clamped, non-overlapping) the path was built from.
    public let regions: [ZoomRegion]
    public let duration: Double
    /// (ln scale, centre x, centre y) at `sampleRate`.
    let table: [SIMD3<Float>]

    enum State: Equatable { case wide, region(Int) }
    struct Segment { var t0: Double; var t1: Double; var from: State; var to: State }

    public init(regions: [ZoomRegion], cursor: CursorPath, duration: Double) {
        let duration = max(0, duration.isFinite ? duration : 0)
        self.duration = duration
        // Sanitise: clamp, drop no-ops, sort, split overlaps at the midpoint.
        var rs = regions.compactMap { r -> ZoomRegion? in
            var r = r
            r.range = TimeRange(start: max(0, r.range.start), end: min(duration, r.range.end))
            r.scale = min(8, max(1, r.scale.isFinite ? r.scale : 1))
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

        // Transitions in time order.
        var transitions: [Segment] = []
        for (k, r) in rs.enumerated() {
            let d = min(Spring.zoomDuration(from: 1, to: r.scale), max(0.3, r.range.duration))
            let inSeg = Segment(t0: r.range.start - d / 2, t1: r.range.start + d / 2, from: .wide, to: .region(k))
            if let last = transitions.last, last.to == .wide, case .region(let p) = last.from, p == k - 1,
               inSeg.t0 < last.t1 + 0.3 {
                // The previous region's zoom-out has not started yet: connect with a direct pan/zoom.
                transitions.removeLast()
                let prev = rs[p]
                let a = prev.focus ?? .center, b = r.focus ?? .center
                let dist = hypot(b.x - a.x, b.y - a.y)
                let dd = max(Spring.zoomDuration(from: prev.scale, to: r.scale), min(1.2, 0.7 + 0.8 * dist))
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

        // Follow state for cursor-following regions (dead zone + spring), stepped through time.
        let rate = Self.sampleRate
        let dt = 1 / rate
        let count = max(1, Int((duration * rate).rounded(.up)) + 1)
        var out = [SIMD3<Float>](repeating: SIMD3(0, 0.5, 0.5), count: count)
        let followOmega = 5.0
        let followDecay = exp(-followOmega * dt)
        var followRegion = -1
        var fx = 0.5, fy = 0.5, fvx = 0.0, fvy = 0.0, tx = 0.5, ty = 0.5

        func stepFollow(_ k: Int, _ t: Double) {
            let s = rs[k].scale
            let cur = cursor.position(at: t) ?? .center
            let cx = min(1, max(0, cur.x)), cy = min(1, max(0, cur.y))
            if followRegion != k {
                followRegion = k
                let c = clampCenter(NormPoint(x: cx, y: cy), scale: s)
                fx = c.x; fy = c.y; tx = c.x; ty = c.y; fvx = 0; fvy = 0
                return
            }
            let dead = 0.25 / s
            if cx > tx + dead { tx = cx - dead } else if cx < tx - dead { tx = cx + dead }
            if cy > ty + dead { ty = cy - dead } else if cy < ty - dead { ty = cy + dead }
            let tc = clampCenter(NormPoint(x: tx, y: ty), scale: s)
            tx = tc.x; ty = tc.y
            Spring.step(x: &fx, v: &fvx, target: tx, omega: followOmega, dt: dt, decay: followDecay)
            Spring.step(x: &fy, v: &fvy, target: ty, omega: followOmega, dt: dt, decay: followDecay)
        }
        func resolve(_ st: State) -> (s: Double, c: NormPoint) {
            switch st {
            case .wide: return (1, .center)
            case .region(let k):
                let s = rs[k].scale
                if let f = rs[k].focus { return (s, clampCenter(f, scale: s)) }
                return (s, clampCenter(NormPoint(x: fx, y: fy), scale: s))
            }
        }

        var seg = 0
        for n in 0..<count {
            let t = Double(n) * dt
            while seg < transitions.count, transitions[seg].t1 <= t { seg += 1 }
            // Current state: inside a transition, or holding the state the last transition reached.
            var from: State, to: State, u = 1.0
            if seg < transitions.count, transitions[seg].t0 <= t {
                from = transitions[seg].from; to = transitions[seg].to
                u = Spring.ease((t - transitions[seg].t0) / (transitions[seg].t1 - transitions[seg].t0))
            } else {
                from = seg > 0 ? transitions[seg - 1].to : .wide
                to = from
            }
            // Advance the follower for whichever following region is involved.
            for st in [from, to] {
                if case .region(let k) = st, rs[k].focus == nil { stepFollow(k, t); break }
            }
            let a = resolve(from), b = resolve(to)
            let la = log(a.s), lb = log(b.s)
            let ls = la + (lb - la) * u
            let s = exp(ls)
            var c: NormPoint
            if abs(lb - la) < 1e-4 {
                c = NormPoint(x: a.c.x + (b.c.x - a.c.x) * u, y: a.c.y + (b.c.y - a.c.y) * u)
            } else {
                // Zoom about the fixed point A where (A - c0)·s0 == (A - c1)·s1.
                let ax = (a.c.x * a.s - b.c.x * b.s) / (a.s - b.s)
                let ay = (a.c.y * a.s - b.c.y * b.s) / (a.s - b.s)
                c = NormPoint(x: ax - (ax - a.c.x) * a.s / s, y: ay - (ay - a.c.y) * a.s / s)
            }
            c = clampCenter(c, scale: s)
            out[n] = SIMD3(Float(ls), Float(c.x), Float(c.y))
        }
        table = out
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
        return (s, clampCenter(NormPoint(x: Double(v.y), y: Double(v.z)), scale: s))
    }

    /// The visible source rectangle at time `t`.
    public func viewport(at t: Double) -> NormRect {
        let (s, c) = transform(at: t)
        return NormRect(x: c.x - 0.5 / s, y: c.y - 0.5 / s, width: 1 / s, height: 1 / s)
    }
}
