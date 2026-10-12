import Foundation

/// Maps between the recording timeline (source seconds) and the edited output timeline,
/// given the trim range and cuts. Kept segments are played back to back.
public struct EditTimeline: Hashable, Sendable {
    /// Kept source ranges in order.
    public let kept: [TimeRange]

    public init(duration: Double, trim: TimeRange?, cuts: [TimeRange]) {
        let base = trim.map { TimeRange(start: max(0, $0.start), end: min(duration, $0.end)) }
            ?? TimeRange(start: 0, end: duration)
        var ranges = [base]
        for cut in cuts.sorted(by: { $0.start < $1.start }) where cut.duration > 0 {
            var next: [TimeRange] = []
            for r in ranges {
                guard r.overlaps(cut) else { next.append(r); continue }
                if cut.start > r.start { next.append(TimeRange(start: r.start, end: cut.start)) }
                if cut.end < r.end { next.append(TimeRange(start: cut.end, end: r.end)) }
            }
            ranges = next
        }
        kept = ranges.filter { $0.duration > 1e-6 }
    }

    public init(manifest: ProjectManifest, edit: EditDocument) {
        self.init(duration: manifest.duration, trim: edit.trim, cuts: edit.cuts)
    }

    /// Output duration in seconds.
    public var duration: Double { kept.reduce(0) { $0 + $1.duration } }

    /// Source time for an output time (clamped to the output range).
    public func sourceTime(forOutput t: Double) -> Double {
        var remaining = max(0, t)
        for r in kept {
            if remaining < r.duration { return r.start + remaining }
            remaining -= r.duration
        }
        return kept.last?.end ?? 0
    }

    /// Output time for a source time, or `nil` if that moment was cut.
    public func outputTime(forSource t: Double) -> Double? {
        var acc = 0.0
        for r in kept {
            if r.contains(t) { return acc + (t - r.start) }
            acc += r.duration
        }
        return nil
    }
}
