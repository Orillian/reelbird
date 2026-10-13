import Foundation

/// Plans automatic zoom "shots" from what the user did: clicks, and typing bursts when key events exist.
///
/// A still pointer is no reason to zoom. Clicks close in time (and space) become one shot whose depth is
/// fitted to the clicks' bounding box, with a lead-in before the first click and a hold after the last.
/// Shots that nearly touch become a pan instead of zooming out and back in. The planner is pure and
/// deterministic: the same events always give the same regions (ids included).
///
/// Defaults, chosen for calm: the default intensity zooms at most 1.8× (1.35× subtle, 2.25× punchy), the
/// camera is settled about half a second before the first click of a shot (lead-in 1.0 s, with the
/// transition centred on the region start) and holds 1.8 s after the last. Two shots that would need a pan
/// with less than 2.6 s between their clicks keep only the more substantial one: a whip pan right after a
/// click hides what the click did, and fewer camera moves is the single biggest cure for motion sickness.
/// Clicks only group into one shot while the group still allows 80% of the full depth, so a typing shot is
/// not flattened to a barely-there zoom by a toolbar click seconds earlier.
public enum AutoZoomPlanner {
    /// Tunables, exposed for tests and the editor's debug overlay.
    public struct Tuning: Sendable {
        public var leadIn = 1.0
        public var holdAfter = 1.8
        /// Box margin on each side, as a fraction of the frame.
        public var fitMargin = 0.1
        /// Regions closer than this become adjacent so the camera pans between them.
        public var panGap = 1.2
        /// Shots whose clicks are closer than this need a pan too fast to follow; keep the stronger one.
        public var minPanGap = 2.6
        /// Ignore clicks this close to the end (the click that stopped the recording).
        public var stopGuard = 1.0
        /// Shots shallower than this are not worth zooming.
        public var minimumScale = 1.25
        public init() {}
    }

    struct Target { var t0: Double; var t1: Double; var minX, minY, maxX, maxY: Double }
    struct Shot {
        var t0: Double; var t1: Double; var minX, minY, maxX, maxY: Double; var start: Double; var end: Double
        /// How much happens in the shot (targets and time); decides which of two clashing shots survives.
        var weight: Double
    }

    /// Plans zoom regions for a recording of `duration` seconds. `intensity` 0 = subtle and rare,
    /// 1 = punchy and frequent. Returned regions are sorted, non-overlapping, `source == .auto`.
    public static func plan(events: [InputEvent], duration: Double, intensity: Double) -> [ZoomRegion] {
        plan(events: events, duration: duration, intensity: intensity, tuning: Tuning())
    }

    public static func plan(events: [InputEvent], duration: Double, intensity: Double, tuning: Tuning) -> [ZoomRegion] {
        guard duration > 0 else { return [] }
        let k = min(1, max(0, intensity))
        let mergeGap = 3.0 - 0.5 * k
        let maxScale = 1.35 + 0.9 * k
        let minRegion = 1.6 - 0.6 * k
        let m = tuning.fitMargin
        // Grouping must not flatten the zoom: merge only while the union keeps 80% of the full depth.
        let mergeFloor = max(tuning.minimumScale + 0.05, 0.8 * maxScale)

        func fit(_ w: Double, _ h: Double) -> Double { min(1 / max(1e-6, w + 2 * m), 1 / max(1e-6, h + 2 * m)) }
        func inside(_ x: Double, _ y: Double) -> Bool { x >= -0.005 && x <= 1.005 && y >= -0.005 && y <= 1.005 }

        var sorted = events
        if !isSortedByTime(sorted) { sorted.sort { $0.t < $1.t } }

        var targets: [Target] = []
        // Clicks.
        for e in sorted where e.type == .down {
            guard let x = e.x, let y = e.y, inside(x, y), e.t >= 0, e.t < duration - tuning.stopGuard else { continue }
            let cx = min(1, max(0, x)), cy = min(1, max(0, y))
            targets.append(Target(t0: e.t, t1: e.t, minX: cx, minY: cy, maxX: cx, maxY: cy))
        }
        // Typing bursts: ≥ 4 plain keys with gaps ≤ 1.2 s spanning ≥ 0.8 s. Shortcuts are not typing.
        var burst: [Double] = []
        var lastFocus: NormRect?, lastClick: NormPoint?, lastPointer: NormPoint?
        var burstFocus: NormRect?, burstClick: NormPoint?, burstPointer: NormPoint?
        func flush() {
            defer { burst.removeAll(keepingCapacity: true) }
            guard burst.count >= 4, let a = burst.first, let b = burst.last, b - a >= 0.8,
                  b < duration - tuning.stopGuard else { return }
            if let r = burstFocus, r.width > 0, r.height > 0 {
                targets.append(Target(t0: a, t1: b, minX: max(0, r.x), minY: max(0, r.y),
                                      maxX: min(1, r.x + r.width), maxY: min(1, r.y + r.height)))
            } else if let p = burstClick ?? burstPointer, inside(p.x, p.y) {
                // No focus rectangle (Accessibility off): text grows to the right of where the user clicked,
                // so frame the click plus room for what they typed (~0.6% of the width per character, at most
                // 30%) instead of centring on the click and showing mostly what lies to its left.
                let x = min(1, max(0, p.x)), y = min(1, max(0, p.y))
                let grow = min(0.3, 0.006 * Double(burst.count))
                targets.append(Target(t0: a, t1: b, minX: x, minY: y, maxX: min(1, x + grow), maxY: y))
            }
        }
        for e in sorted {
            switch e.type {
            case .focus: lastFocus = e.rect
            case .down: lastClick = e.point; lastPointer = e.point
            case .move: lastPointer = e.point
            case .key:
                let mods = Set(e.mods ?? [])
                if !mods.isDisjoint(with: ["⌘", "⌃", "cmd", "ctrl"]) { continue }
                if let last = burst.last, e.t - last > 1.2 { flush() }
                if burst.isEmpty { burstFocus = lastFocus; burstClick = lastClick; burstPointer = lastPointer }
                burst.append(e.t)
            default: break
            }
        }
        flush()
        targets.sort { $0.t0 < $1.t0 }

        // Cluster targets into shots.
        var shots: [Shot] = []
        for tg in targets {
            if var s = shots.last {
                let ux0 = min(s.minX, tg.minX), uy0 = min(s.minY, tg.minY)
                let ux1 = max(s.maxX, tg.maxX), uy1 = max(s.maxY, tg.maxY)
                if tg.t0 - s.t1 <= mergeGap, fit(ux1 - ux0, uy1 - uy0) >= mergeFloor {
                    s.t1 = max(s.t1, tg.t1); s.minX = ux0; s.minY = uy0; s.maxX = ux1; s.maxY = uy1
                    s.weight += 1 + (tg.t1 - tg.t0)
                    shots[shots.count - 1] = s
                    continue
                }
            }
            shots.append(Shot(t0: tg.t0, t1: tg.t1, minX: tg.minX, minY: tg.minY, maxX: tg.maxX, maxY: tg.maxY, start: 0, end: 0,
                              weight: 1 + (tg.t1 - tg.t0)))
        }
        for i in shots.indices {
            shots[i].start = max(0, shots[i].t0 - tuning.leadIn)
            shots[i].end = min(duration, shots[i].t1 + tuning.holdAfter)
        }
        shots.removeAll { fit($0.maxX - $0.minX, $0.maxY - $0.minY) < tuning.minimumScale || $0.end - $0.start < minRegion }

        // Resolve neighbours: merge when both fit in one view, else meet in the middle (a pan).
        var resolved: [Shot] = []
        for s in shots {
            var s = s
            while true {
                guard var prev = resolved.last, s.start - prev.end < tuning.panGap else { resolved.append(s); break }
                let ux0 = min(prev.minX, s.minX), uy0 = min(prev.minY, s.minY)
                let ux1 = max(prev.maxX, s.maxX), uy1 = max(prev.maxY, s.maxY)
                if fit(ux1 - ux0, uy1 - uy0) >= mergeFloor {
                    prev.t1 = max(prev.t1, s.t1); prev.end = max(prev.end, s.end)
                    prev.minX = ux0; prev.minY = uy0; prev.maxX = ux1; prev.maxY = uy1
                    prev.weight += s.weight
                    resolved[resolved.count - 1] = prev
                    break
                } else if s.t0 - prev.t1 < tuning.minPanGap {
                    // Too close for a calm pan: keep the stronger shot (the later one on a tie).
                    if prev.weight > s.weight { break }
                    resolved.removeLast()
                    // `s` may now clash with the shot before; check again.
                    continue
                } else {
                    // Pan: leave 0.8 s after the last click, arrive 0.2 s before the next.
                    let mid = min(max((prev.t1 + 0.8 + s.t0 - 0.2) / 2, prev.t1 + 0.3), s.t0)
                    prev.end = mid; s.start = mid
                    resolved[resolved.count - 1] = prev
                    resolved.append(s)
                    break
                }
            }
        }

        // Every click must be on screen when it happens. A click a shot doesn't show (one dropped above, or a
        // stray click near a shot) pushes that shot's zoom-in to start after it, or its zoom-out to finish
        // before it. A view's edges move monotonically through a zoom, so "visible at both ends" suffices.
        var out: [(shot: Shot, scale: Double, focus: NormPoint)] = resolved.map { s in
            let scale = (min(maxScale, fit(s.maxX - s.minX, s.maxY - s.minY)) * 1000).rounded() / 1000
            return (s, scale, clampCenter(NormPoint(x: (s.minX + s.maxX) / 2, y: (s.minY + s.maxY) / 2), scale: scale))
        }
        let clicks = targets.filter { $0.t0 == $0.t1 }
        for k in out.indices {
            var sh = out[k].shot
            let scale = out[k].scale, f = out[k].focus
            let half = 0.5 / scale - 0.03
            let d = Spring.zoomDuration(from: 1, to: scale)
            let pannedIn = k > 0 && out[k - 1].shot.end >= sh.start - 1e-9
            let pannedOut = k + 1 < out.count && out[k + 1].shot.start <= sh.end + 1e-9
            for c in clicks where abs(c.minX - f.x) > half || abs(c.minY - f.y) > half {
                if !pannedIn, c.t0 < sh.t0, c.t0 > sh.start - d / 2 - 0.15 {
                    sh.start = min(sh.t0, c.t0 + 0.15 + d / 2)
                } else if !pannedOut, c.t0 > sh.t1, c.t0 < sh.end + d / 2 + 0.15 {
                    sh.end = max(sh.t1 + 0.3, c.t0 - 0.15 - d / 2)
                }
            }
            out[k].shot = sh
        }

        return out.filter { $0.shot.end - $0.shot.start > 0.5 }.enumerated().map { i, o in
            ZoomRegion(id: "auto-\(i + 1)", range: TimeRange(start: o.shot.start, end: o.shot.end), scale: o.scale,
                       focus: o.focus, source: .auto)
        }
    }

    /// Replaces the `.auto` regions in `existing` with a fresh plan, keeping every `.user` region.
    /// Auto regions that would overlap a user region are dropped (the user's choice wins).
    public static func merged(existing: [ZoomRegion], events: [InputEvent], duration: Double, intensity: Double) -> [ZoomRegion] {
        // A zoom turned off stays off (and keeps automatic zooms away from that moment), like a zoom you made.
        let user = existing.filter { $0.source == .user || !$0.enabled }
        let auto = plan(events: events, duration: duration, intensity: intensity)
            .filter { a in !user.contains { $0.range.overlaps(a.range) } }
        return (user + auto).sorted { $0.range.start < $1.range.start }
    }
}

func isSortedByTime(_ e: [InputEvent]) -> Bool {
    var prev = -Double.infinity
    for x in e { if x.t < prev { return false }; prev = x.t }
    return true
}
