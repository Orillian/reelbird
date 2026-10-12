import Foundation

/// The smoothed cursor track, computed once from the event log so preview and export draw the same path.
///
/// Raw pointer samples are resampled to a fixed rate and run through a critically damped spring (with
/// look-ahead so the smoothed cursor does not trail the video), then pinned back onto the raw position
/// around clicks so clicks land exactly where they happened. The result is a flat table: sampling is O(1),
/// click and cursor-image lookups are O(log n). A one-hour recording builds in well under a second.
public struct CursorPath: Sendable {
    /// Table rate in samples per second.
    public static let sampleRate: Double = 120

    /// The smoothing amount the path was built with (0 = raw, 1 = very smooth).
    public let smoothing: Double
    /// Time of table sample 0.
    let start: Double
    /// Smoothed positions at `sampleRate`.
    let table: [SIMD2<Float>]
    /// Left-button and right-button presses (`.down` events with a position), by time.
    public let clickEvents: [InputEvent]
    let clickTimes: [Double]
    /// Intervals in which the pointer moved or clicked (merged when closer than 0.1 s).
    let activeStarts: [Double]
    let activeEnds: [Double]
    let imageTimes: [Double]
    let imageIDs: [String]

    /// Builds the path. Events need not be sorted.
    public init(events: [InputEvent], smoothing: Double) {
        self.smoothing = min(1, max(0, smoothing))
        var raw: [(t: Double, x: Double, y: Double)] = []
        raw.reserveCapacity(events.count)
        var clicks: [InputEvent] = []
        var images: [(Double, String)] = []
        for e in events {
            switch e.type {
            case .move, .down, .up, .scroll:
                if let x = e.x, let y = e.y, x.isFinite, y.isFinite, e.t.isFinite { raw.append((e.t, x, y)) }
                if e.type == .down, e.x != nil, e.y != nil { clicks.append(e) }
            case .cursor:
                if let id = e.image { images.append((e.t, id)) }
            default:
                break
            }
        }
        var rawSorted = true
        for i in raw.indices.dropFirst() where raw[i].t < raw[i - 1].t { rawSorted = false; break }
        if !rawSorted { raw.sort { $0.t < $1.t } }
        clicks.sort { $0.t < $1.t }
        images.sort { $0.0 < $1.0 }
        clickEvents = clicks
        clickTimes = clicks.map(\.t)
        imageTimes = images.map(\.0)
        imageIDs = images.map(\.1)

        // Activity intervals for idle hiding.
        var aStarts: [Double] = [], aEnds: [Double] = []
        var prev: (x: Double, y: Double)?
        var clickIdx = 0
        func mark(_ t: Double) {
            if let last = aEnds.last, t - last < 0.1 { aEnds[aEnds.count - 1] = max(last, t) } else { aStarts.append(t); aEnds.append(t) }
        }
        for s in raw {
            while clickIdx < clickTimes.count, clickTimes[clickIdx] <= s.t { mark(clickTimes[clickIdx]); clickIdx += 1 }
            if let p = prev {
                if abs(p.x - s.x) > 1e-4 || abs(p.y - s.y) > 1e-4 { mark(s.t) }
            } else {
                mark(s.t)
            }
            prev = (s.x, s.y)
        }
        while clickIdx < clickTimes.count { mark(clickTimes[clickIdx]); clickIdx += 1 }
        activeStarts = aStarts
        activeEnds = aEnds

        guard let first = raw.first, let last = raw.last else {
            start = 0; table = []; return
        }
        start = first.t
        let rate = Self.sampleRate
        let dt = 1 / rate
        let tail = 1.5
        let count = Int(((last.t - first.t + tail) * rate).rounded(.up)) + 1
        let s = self.smoothing
        // Spring natural frequency: ~40 rad/s (barely smoothed) down to ~7 rad/s (very smooth).
        let omega = 40 * pow(7.0 / 40.0, s)
        let lead = s < 0.01 ? 0 : min(0.25, 2 / omega)
        let decay = exp(-omega * dt)

        var out = [SIMD2<Float>](repeating: .zero, count: count)
        raw.withUnsafeBufferPointer { r in
            out.withUnsafeMutableBufferPointer { o in
                var j = 0
                let n = r.count
                // Raw position at a (monotonically increasing) time. A gap between samples means the
                // pointer sat still, so hold the earlier sample until just before the next one.
                func rawAt(_ t: Double) -> (Double, Double) {
                    while j + 1 < n, r[j + 1].t <= t { j += 1 }
                    let a = r[j]
                    if t <= a.t || j + 1 >= n { return (a.x, a.y) }
                    let b = r[j + 1]
                    var t0 = a.t
                    if b.t - a.t > 0.05 { t0 = b.t - 1.0 / 60.0 }
                    if t <= t0 { return (a.x, a.y) }
                    let u = (t - t0) / (b.t - t0)
                    return (a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u)
                }
                if s < 0.01 {
                    for i in 0..<count {
                        let p = rawAt(first.t + Double(i) * dt)
                        o[i] = SIMD2(Float(p.0), Float(p.1))
                    }
                    return
                }
                var x = first.x, y = first.y, vx = 0.0, vy = 0.0
                for i in 0..<count {
                    let p = rawAt(first.t + Double(i) * dt + lead)
                    Spring.step(x: &x, v: &vx, target: p.0, omega: omega, dt: dt, decay: decay)
                    Spring.step(x: &y, v: &vy, target: p.1, omega: omega, dt: dt, decay: decay)
                    o[i] = SIMD2(Float(x), Float(y))
                }
                // Pin to the raw position around clicks so they land exactly on target.
                j = 0
                let pinHold = 0.04, pinFade = 0.22
                for c in clicks {
                    guard let cx = c.x, let cy = c.y else { continue }
                    let lo = max(0, Int(((c.t - pinHold - pinFade - first.t) * rate).rounded(.down)))
                    let hi = min(count - 1, Int(((c.t + pinHold + pinFade - first.t) * rate).rounded(.up)))
                    if lo > hi { continue }
                    for i in lo...hi {
                        let t = first.t + Double(i) * dt
                        let d = abs(t - c.t)
                        let w: Double
                        if d <= pinHold { w = 1 } else {
                            let u = min(1, (d - pinHold) / pinFade)
                            w = 1 - u * u * (3 - 2 * u)
                        }
                        if w <= 0 { continue }
                        let cur = o[i]
                        let px = Double(cur.x) + (cx - Double(cur.x)) * w
                        let py = Double(cur.y) + (cy - Double(cur.y)) * w
                        o[i] = SIMD2(Float(px), Float(py))
                    }
                }
            }
        }
        table = out
    }

    /// Whether the log had any pointer positions.
    public var isEmpty: Bool { table.isEmpty }

    /// Smoothed pointer position at time `t` (normalized, may fall outside 0...1 when the pointer left
    /// the captured area). Before the first sample the first position is returned. `nil` if no positions.
    public func position(at t: Double) -> NormPoint? {
        guard !table.isEmpty else { return nil }
        let f = (t - start) * Self.sampleRate
        if !(f > 0) { let p = table[0]; return NormPoint(x: Double(p.x), y: Double(p.y)) }
        let i = Int(f)
        if i >= table.count - 1 { let p = table[table.count - 1]; return NormPoint(x: Double(p.x), y: Double(p.y)) }
        let u = Float(f - Double(i))
        let p = table[i] + (table[i + 1] - table[i]) * u
        return NormPoint(x: Double(p.x), y: Double(p.y))
    }

    /// Smoothed velocity in normalized units per second at `t`.
    public func velocity(at t: Double) -> (dx: Double, dy: Double) {
        guard table.count > 1 else { return (0, 0) }
        let i = min(table.count - 2, max(0, Int((t - start) * Self.sampleRate)))
        let d = table[i + 1] - table[i]
        return (Double(d.x) * Self.sampleRate, Double(d.y) * Self.sampleRate)
    }

    /// Press events within `window` seconds of `t` (either side), oldest first.
    public func clicks(near t: Double, window: Double) -> [InputEvent] {
        var i = lowerBound(clickTimes, t - window)
        var out: [InputEvent] = []
        while i < clickTimes.count, clickTimes[i] <= t + window { out.append(clickEvents[i]); i += 1 }
        return out
    }

    /// Calls `body` for each press within `window` before `t` (inclusive), newest first, without allocating.
    public func forEachRecentClick(before t: Double, window: Double, limit: Int, _ body: (InputEvent) -> Void) {
        var i = upperBound(clickTimes, t) - 1
        var n = 0
        while i >= 0, n < limit, clickTimes[i] >= t - window { body(clickEvents[i]); i -= 1; n += 1 }
    }

    /// The cursor image (file stem in `cursors/`) shown at `t`, or `nil` if the log has none.
    public func imageID(at t: Double) -> String? {
        guard !imageIDs.isEmpty else { return nil }
        let i = upperBound(imageTimes, t) - 1
        return imageIDs[max(0, i)]
    }

    /// Cursor opacity at `t` when hiding after `hideAfter` seconds of no movement (0 = never hide).
    /// Fades out over 0.3 s and back in just before the pointer moves again.
    public func opacity(at t: Double, hideAfter: Double) -> Double {
        guard hideAfter > 0 else { return 1 }
        let i = upperBound(activeStarts, t) - 1
        let lastActive = i >= 0 ? min(t, activeEnds[i]) : 0
        let idle = t - lastActive
        var o = 1 - smoothstep(hideAfter, hideAfter + 0.3, idle)
        let next = i + 1 < activeStarts.count ? activeStarts[i + 1] : Double.infinity
        if next - t < 0.15 { o = max(o, 1 - (next - t) / 0.15) }
        return o
    }
}

@inline(__always) func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let u = min(1, max(0, (x - a) / (b - a)))
    return u * u * (3 - 2 * u)
}

/// First index whose value is >= `x`.
@inline(__always) func lowerBound(_ a: [Double], _ x: Double) -> Int {
    var lo = 0, hi = a.count
    while lo < hi { let m = (lo + hi) >> 1; if a[m] < x { lo = m + 1 } else { hi = m } }
    return lo
}

/// First index whose value is > `x`.
@inline(__always) func upperBound(_ a: [Double], _ x: Double) -> Int {
    var lo = 0, hi = a.count
    while lo < hi { let m = (lo + hi) >> 1; if a[m] <= x { lo = m + 1 } else { hi = m } }
    return lo
}
