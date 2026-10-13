import Foundation

/// The smoothed cursor track, computed once from the event log so preview and export draw the same path.
///
/// Raw pointer samples are resampled to a fixed rate and smoothed with a *zero-phase* filter: a critically
/// damped spring run forwards and then backwards over the whole track. The two passes cancel each other's
/// lag exactly, so the rendered cursor never trails (or leads) the real one; only jitter, tremor and the
/// little corrective jumps at the end of a reach are smoothed away, leaving the gliding arc. Around clicks
/// and during drags the path blends back onto the raw pointer, so clicks land exactly where they happened
/// and dragged content stays attached to the cursor. The result is a flat table: sampling is O(1), click
/// and cursor-image lookups are O(log n). A one-hour recording builds in well under a second.
public struct CursorPath: Sendable {
    /// Table rate in samples per second.
    public static let sampleRate: Double = 120

    /// Width (standard deviation, seconds) of the smoothing kernel for a smoothing amount.
    ///
    /// `0.14·s^1.2`: the default 0.6 gives 76 ms, which merges a reach's corrective submovement into one
    /// glide while keeping the error on a fast minimum-jerk reach under ~2% of its length; 1.0 gives 140 ms
    /// (floaty); 0.3 gives 33 ms (just removes jitter).
    public static func kernelWidth(smoothing s: Double) -> Double { 0.14 * pow(min(1, max(0, s)), 1.2) }

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
    /// Intervals in which macOS hides the pointer because the user is typing (from a key press to the next
    /// pointer activity).
    let typingStarts: [Double]
    let typingEnds: [Double]
    let imageTimes: [Double]
    let imageIDs: [String]

    /// Builds the path. Events need not be sorted.
    public init(events: [InputEvent], smoothing: Double) {
        self.smoothing = min(1, max(0, smoothing))
        var raw: [(t: Double, x: Double, y: Double)] = []
        raw.reserveCapacity(events.count)
        var clicks: [InputEvent] = []
        var ups: [InputEvent] = []
        var keys: [Double] = []
        var images: [(Double, String)] = []
        for e in events {
            switch e.type {
            case .move, .down, .up, .scroll:
                if let x = e.x, let y = e.y, x.isFinite, y.isFinite, e.t.isFinite { raw.append((e.t, x, y)) }
                if e.type == .down, e.x != nil, e.y != nil { clicks.append(e) }
                if e.type == .up, e.x != nil, e.y != nil { ups.append(e) }
            case .key:
                // Plain typing hides the pointer (NSCursor.setHiddenUntilMouseMoves); shortcuts don't.
                let mods = e.mods ?? []
                if e.t.isFinite, !mods.contains(where: { ["⌘", "⌃", "cmd", "ctrl"].contains($0) }) { keys.append(e.t) }
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
        ups.sort { $0.t < $1.t }
        keys.sort()
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

        // Typing hides the pointer from the key press until the pointer next moves or clicks.
        var tStarts: [Double] = [], tEnds: [Double] = []
        for k in keys {
            if let e = tEnds.last, k <= e { continue }
            let i = upperBound(aStarts, k)
            // The pointer is moving right now: macOS shows it again at once.
            if i > 0, aEnds[i - 1] >= k - 0.02 { continue }
            let next = i < aStarts.count ? aStarts[i] : Double.infinity
            tStarts.append(k); tEnds.append(next)
        }
        typingStarts = tStarts
        typingEnds = tEnds

        guard let first = raw.first, let last = raw.last else {
            start = 0; table = []; return
        }
        start = first.t
        let rate = Self.sampleRate
        let dt = 1 / rate
        let tail = 1.5
        // At most a day: one bogus timestamp in a hand-edited events.jsonl must not allocate gigabytes.
        let span = (last.t - first.t).isFinite ? min(max(0, last.t - first.t), 86_400) : 0
        let count = Int(((span + tail) * rate).rounded(.up)) + 1
        let sigma = Self.kernelWidth(smoothing: self.smoothing)

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
                var rx = [Double](repeating: 0, count: count), ry = [Double](repeating: 0, count: count)
                for i in 0..<count {
                    let p = rawAt(first.t + Double(i) * dt)
                    rx[i] = p.0; ry[i] = p.1
                }
                guard sigma > 0.004 else {
                    for i in 0..<count { o[i] = SIMD2(Float(rx[i]), Float(ry[i])) }
                    return
                }
                // Forward then backward critically damped spring: each pass has variance 2/ω², so ω = 2/σ
                // gives a symmetric kernel of standard deviation σ with zero delay.
                let omega = 2 / sigma
                let decay = exp(-omega * dt)
                var sx = rx, sy = ry
                var x = rx[0], y = ry[0], vx = 0.0, vy = 0.0
                for i in 0..<count {
                    Spring.step(x: &x, v: &vx, target: rx[i], omega: omega, dt: dt, decay: decay)
                    Spring.step(x: &y, v: &vy, target: ry[i], omega: omega, dt: dt, decay: decay)
                    sx[i] = x; sy[i] = y
                }
                x = sx[count - 1]; y = sy[count - 1]; vx = 0; vy = 0
                for i in stride(from: count - 1, through: 0, by: -1) {
                    Spring.step(x: &x, v: &vx, target: sx[i], omega: omega, dt: dt, decay: decay)
                    Spring.step(x: &y, v: &vy, target: sy[i], omega: omega, dt: dt, decay: decay)
                    sx[i] = x; sy[i] = y
                }
                // Blend weights toward the raw pointer: 1 at clicks (±40 ms) and through drags, fading over
                // 180 ms (smoothstep) so the hand-off is invisible.
                var w = [Float](repeating: 0, count: count)
                let pinHold = 0.04, pinFade = 0.18
                func pin(_ a: Double, _ b: Double) {
                    let lo = max(0, Int(((a - pinHold - pinFade - first.t) * rate).rounded(.down)))
                    let hi = min(count - 1, Int(((b + pinHold + pinFade - first.t) * rate).rounded(.up)))
                    guard lo <= hi else { return }
                    for i in lo...hi {
                        let t = first.t + Double(i) * dt
                        let d = t < a ? a - t : (t > b ? t - b : 0)
                        let v: Double
                        if d <= pinHold { v = 1 } else {
                            let u = min(1, (d - pinHold) / pinFade)
                            v = 1 - u * u * (3 - 2 * u)
                        }
                        w[i] = max(w[i], Float(v))
                    }
                }
                var u = 0
                for c in clicks {
                    // A drag: the pointer moved while the button was held. Pin the whole way.
                    while u < ups.count, ups[u].t < c.t { u += 1 }
                    var endT = c.t
                    if u < ups.count, ups[u].t - c.t < 30, let ux = ups[u].x, let uy = ups[u].y, let cx = c.x, let cy = c.y {
                        var moved = abs(ux - cx) + abs(uy - cy) > 0.004
                        if !moved {
                            let k0 = max(0, Int(((c.t - first.t) * rate).rounded())), k1 = min(count - 1, Int(((ups[u].t - first.t) * rate).rounded()))
                            if k0 <= k1 { for k in k0...k1 where abs(rx[k] - cx) + abs(ry[k] - cy) > 0.004 { moved = true; break } }
                        }
                        if moved { endT = ups[u].t }
                    }
                    pin(c.t, endT)
                }
                for i in 0..<count {
                    let k = Double(w[i])
                    var px = sx[i] + (rx[i] - sx[i]) * k, py = sy[i] + (ry[i] - sy[i]) * k
                    // Clicks land exactly where they happened (the raw track holds the click position there).
                    if k >= 1 { px = rx[i]; py = ry[i] }
                    o[i] = SIMD2(Float(px), Float(py))
                }
                // Exact positions at the click instants (the table may not sample them exactly).
                for c in clicks {
                    guard let cx = c.x, let cy = c.y else { continue }
                    let f = (c.t - first.t) * rate
                    let i0 = Int(f.rounded(.down))
                    for i in [i0, i0 + 1] where i >= 0 && i < count && w[i] >= 1 { o[i] = SIMD2(Float(cx), Float(cy)) }
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
        if f >= Double(table.count - 1) { let p = table[table.count - 1]; return NormPoint(x: Double(p.x), y: Double(p.y)) }
        let i = Int(f)
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

    /// Cursor opacity at `t`: hidden while typing (as macOS does), and after `hideAfter` seconds of no
    /// movement (0 = never). Fades out over 0.3 s (0.15 s for typing) and back in just before the pointer
    /// moves again.
    public func opacity(at t: Double, hideAfter: Double) -> Double {
        var o = 1.0
        let i = upperBound(activeStarts, t) - 1
        let next = i + 1 < activeStarts.count ? activeStarts[i + 1] : Double.infinity
        if hideAfter > 0 {
            let lastActive = i >= 0 ? min(t, activeEnds[i]) : 0
            o = 1 - smoothstep(hideAfter, hideAfter + 0.3, t - lastActive)
        }
        let k = upperBound(typingStarts, t) - 1
        if k >= 0, t < typingEnds[k] {
            o = min(o, 1 - smoothstep(typingStarts[k], typingStarts[k] + 0.15, t))
        }
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
