import Foundation

/// Plans automatic zoom "shots" from what the user did: clicks, and typing bursts when key events exist.
///
/// A still pointer is no reason to zoom. Clicks close in time (and space) become one shot whose depth is
/// fitted to the clicks' bounding box, with a lead-in before the first click and a hold after the last.
/// Shots that nearly touch become a pan instead of zooming out and back in. The planner is pure and
/// deterministic: the same events always give the same regions (ids included).
public enum AutoZoomPlanner {
    /// Tunables, exposed for tests and the editor's debug overlay.
    public struct Tuning: Sendable {
        public var leadIn = 0.6
        public var holdAfter = 1.8
        /// Box margin on each side, as a fraction of the frame.
        public var fitMargin = 0.08
        /// Regions closer than this become adjacent so the camera pans between them.
        public var panGap = 1.2
        /// Ignore clicks this close to the end (the click that stopped the recording).
        public var stopGuard = 1.0
        /// Shots shallower than this are not worth zooming.
        public var minimumScale = 1.25
        public init() {}
    }

    struct Target { var t0: Double; var t1: Double; var minX, minY, maxX, maxY: Double }
    struct Shot { var t0: Double; var t1: Double; var minX, minY, maxX, maxY: Double; var start: Double; var end: Double }

    /// Plans zoom regions for a recording of `duration` seconds. `intensity` 0 = subtle and rare,
    /// 1 = punchy and frequent. Returned regions are sorted, non-overlapping, `source == .auto`.
    public static func plan(events: [InputEvent], duration: Double, intensity: Double) -> [ZoomRegion] {
        plan(events: events, duration: duration, intensity: intensity, tuning: Tuning())
    }

    public static func plan(events: [InputEvent], duration: Double, intensity: Double, tuning: Tuning) -> [ZoomRegion] {
        guard duration > 0 else { return [] }
        let k = min(1, max(0, intensity))
        let mergeGap = 3.0 - 0.5 * k
        let maxScale = 1.4 + 1.2 * k
        let minRegion = 1.6 - 0.6 * k
        let m = tuning.fitMargin

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
                let x = min(1, max(0, p.x)), y = min(1, max(0, p.y))
                targets.append(Target(t0: a, t1: b, minX: x, minY: y, maxX: x, maxY: y))
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
                if tg.t0 - s.t1 <= mergeGap, fit(ux1 - ux0, uy1 - uy0) >= tuning.minimumScale + 0.05 {
                    s.t1 = max(s.t1, tg.t1); s.minX = ux0; s.minY = uy0; s.maxX = ux1; s.maxY = uy1
                    shots[shots.count - 1] = s
                    continue
                }
            }
            shots.append(Shot(t0: tg.t0, t1: tg.t1, minX: tg.minX, minY: tg.minY, maxX: tg.maxX, maxY: tg.maxY, start: 0, end: 0))
        }
        for i in shots.indices {
            shots[i].start = max(0, shots[i].t0 - tuning.leadIn)
            shots[i].end = min(duration, shots[i].t1 + tuning.holdAfter)
        }
        shots.removeAll { fit($0.maxX - $0.minX, $0.maxY - $0.minY) < tuning.minimumScale || $0.end - $0.start < minRegion }

        // Resolve neighbours: merge when both fit in one view, else meet in the middle (a pan).
        var resolved: [Shot] = []
        for s in shots {
            guard var prev = resolved.last, s.start - prev.end < tuning.panGap else { resolved.append(s); continue }
            let ux0 = min(prev.minX, s.minX), uy0 = min(prev.minY, s.minY)
            let ux1 = max(prev.maxX, s.maxX), uy1 = max(prev.maxY, s.maxY)
            if fit(ux1 - ux0, uy1 - uy0) >= tuning.minimumScale + 0.05 {
                prev.t1 = max(prev.t1, s.t1); prev.end = max(prev.end, s.end)
                prev.minX = ux0; prev.minY = uy0; prev.maxX = ux1; prev.maxY = uy1
                resolved[resolved.count - 1] = prev
            } else {
                var next = s
                let mid = min(max((prev.t1 + s.t0) / 2, prev.t1 + 0.3), s.t0)
                prev.end = mid; next.start = mid
                resolved[resolved.count - 1] = prev
                resolved.append(next)
            }
        }

        return resolved.enumerated().map { i, s in
            let scale = (min(maxScale, fit(s.maxX - s.minX, s.maxY - s.minY)) * 1000).rounded() / 1000
            let focus = clampCenter(NormPoint(x: (s.minX + s.maxX) / 2, y: (s.minY + s.maxY) / 2), scale: scale)
            return ZoomRegion(id: "auto-\(i + 1)", range: TimeRange(start: s.start, end: s.end), scale: scale,
                              focus: focus, source: .auto)
        }
    }

    /// Replaces the `.auto` regions in `existing` with a fresh plan, keeping every `.user` region.
    /// Auto regions that would overlap a user region are dropped (the user's choice wins).
    public static func merged(existing: [ZoomRegion], events: [InputEvent], duration: Double, intensity: Double) -> [ZoomRegion] {
        let user = existing.filter { $0.source == .user }
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
