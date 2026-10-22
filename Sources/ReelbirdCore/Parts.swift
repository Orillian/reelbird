import Foundation

/// The editor timeline's parts: the stretches of the recording between split points, cut edges and the trim.
/// A part is what a click selects, what Delete cuts and what its edge handles trim. A cut removes its stretch from
/// every track at once (screen, voice, camera, zooms and the rest stay in sync). Pure; recording timeline.
public enum Parts {
    /// Shortest part an edge drag leaves.
    public static let minDuration = 0.3

    /// The part containing `t`: bounded by the trim, split points and the edges of cuts.
    public static func part(containing t: Double, duration: Double, trim: TimeRange?, splits: [Double], cuts: [TimeRange]) -> TimeRange {
        let lowerBound = trim?.start ?? 0, upperBound = trim?.end ?? duration
        let edges = splits + cuts.flatMap { [$0.start, $0.end] }
        let lower = ([lowerBound] + edges.filter { $0 <= t && $0 >= lowerBound }).max() ?? lowerBound
        let upper = ([upperBound] + edges.filter { $0 > t && $0 <= upperBound }).min() ?? upperBound
        return TimeRange(start: lower, end: max(lower, upper))
    }

    /// What dragging an edge of `part` to `to` does to the cuts and the trim, from the state before the drag.
    ///
    /// - The outer edge of the first or last part moves the trim.
    /// - Dragging an edge inward cuts what it passes over.
    /// - Dragging an edge outward brings back cut footage next to it, up to the start (or end) of that cut; next to a
    ///   split point with nothing cut there, it can't move outward (the neighbouring part keeps its footage).
    /// The part keeps at least `minDuration`.
    public static func trimEdge(of part: TimeRange, leading: Bool, to target: Double, duration: Double,
                                trim: TimeRange?, cuts: [TimeRange]) -> (trim: TimeRange?, cuts: [TimeRange], part: TimeRange) {
        let eps = 1e-6
        var cuts = merged(cuts)
        var trim = trim
        let fullTrim = trim ?? TimeRange(start: 0, end: duration)
        if leading {
            let x = min(target, part.end - minDuration)
            if abs(part.start - fullTrim.start) < eps {
                let start = max(0, x)
                trim = normalizedTrim(TimeRange(start: start, end: fullTrim.end), duration: duration)
                return (trim, cuts, TimeRange(start: start, end: part.end))
            }
            if x > part.start + eps {
                cuts = merged(cuts + [TimeRange(start: part.start, end: x)])
                return (trim, cuts, TimeRange(start: x, end: part.end))
            }
            guard let i = cuts.firstIndex(where: { abs($0.end - part.start) < 1e-3 }) else { return (trim, cuts, part) }
            let start = max(cuts[i].start, x)
            if start - cuts[i].start < 0.05 { cuts.remove(at: i) } else { cuts[i].end = start }
            return (trim, cuts, TimeRange(start: start, end: part.end))
        } else {
            let x = max(target, part.start + minDuration)
            if abs(part.end - fullTrim.end) < eps {
                let end = min(duration, x)
                trim = normalizedTrim(TimeRange(start: fullTrim.start, end: end), duration: duration)
                return (trim, cuts, TimeRange(start: part.start, end: end))
            }
            if x < part.end - eps {
                cuts = merged(cuts + [TimeRange(start: x, end: part.end)])
                return (trim, cuts, TimeRange(start: part.start, end: x))
            }
            guard let i = cuts.firstIndex(where: { abs($0.start - part.end) < 1e-3 }) else { return (trim, cuts, part) }
            let end = min(cuts[i].end, x)
            if cuts[i].end - end < 0.05 { cuts.remove(at: i) } else { cuts[i].start = end }
            return (trim, cuts, TimeRange(start: part.start, end: end))
        }
    }

    /// `nil` for a trim of the whole recording.
    static func normalizedTrim(_ t: TimeRange, duration: Double) -> TimeRange? {
        (t.start <= 0.001 && t.end >= duration - 0.001) ? nil : t
    }

    /// Sorted, with overlapping or touching ranges joined.
    public static func merged(_ ranges: [TimeRange]) -> [TimeRange] {
        var out: [TimeRange] = []
        for r in ranges.filter({ $0.duration > 0 }).sorted(by: { $0.start < $1.start }) {
            if let last = out.last, r.start <= last.end + 1e-6 { out[out.count - 1].end = max(last.end, r.end) } else { out.append(r) }
        }
        return out
    }
}

/// The timeline with its cuts closed up: what's cut takes no room, so parts sit back to back like the edited video
/// (speed changes aside). `collapsed` maps recording time to it; `source` maps back, landing just after a cut at
/// its join.
public struct CutSpace: Hashable, Sendable {
    public let duration: Double
    public let cuts: [TimeRange]

    public init(duration: Double, cuts: [TimeRange]) {
        self.duration = duration
        self.cuts = Parts.merged(cuts.map { TimeRange(start: max(0, $0.start), end: min(duration, $0.end)) })
    }

    /// The length with every cut removed.
    public var collapsedDuration: Double { max(0, duration - cuts.reduce(0) { $0 + $1.duration }) }

    public func collapsed(_ t: Double) -> Double {
        var removed = 0.0
        for c in cuts {
            if t >= c.end { removed += c.duration } else if t > c.start { removed += t - c.start; break } else { break }
        }
        return min(max(0, t - removed), collapsedDuration)
    }

    public func source(_ c: Double) -> Double {
        var s = min(max(0, c), collapsedDuration)
        for cut in cuts {
            if s >= cut.start { s += cut.duration } else { break }
        }
        return min(s, duration)
    }
}
