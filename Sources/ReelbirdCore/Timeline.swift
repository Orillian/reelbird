import Foundation

/// Maps between the recording timeline (source seconds) and the edited output timeline, given the trim range,
/// cuts and speed segments. Kept segments are played back to back, each piece at its speed.
///
/// This is the one time map: preview, export, the timeline, captions, chapters, ducking and share renders all
/// go through `sourceTime(forOutput:)` / `outputTime(forSource:)`, so they always agree.
public struct EditTimeline: Hashable, Sendable {
    /// A kept stretch of the recording at one rate.
    public struct Piece: Hashable, Sendable {
        /// Recording-time range.
        public let source: TimeRange
        /// Playback rate (1 = normal).
        public let rate: Double
        /// Where it starts on the output timeline.
        public let outputStart: Double
        /// Whether its sound plays (segments over 2× are silent unless `SpeedSettings.keepFastAudio`).
        public let audible: Bool
        public var outputDuration: Double { source.duration / rate }
        public var outputEnd: Double { outputStart + outputDuration }
        public var output: TimeRange { TimeRange(start: outputStart, end: outputEnd) }
    }

    /// Kept source ranges in order (trim and cuts applied; speed doesn't split them).
    public let kept: [TimeRange]
    /// The kept ranges split where the speed changes, with their output placement. Back to back, in order.
    public let pieces: [Piece]
    /// Output duration in seconds.
    public let duration: Double

    public init(duration: Double, trim: TimeRange?, cuts: [TimeRange], speed: SpeedSettings = SpeedSettings()) {
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

        let segments = speed.segments
        var pieces: [Piece] = []
        pieces.reserveCapacity(kept.count + 2 * segments.count)
        var out = 0.0
        func add(_ a: Double, _ b: Double, _ rate: Double) {
            guard b - a > 1e-6 else { return }
            let p = Piece(source: TimeRange(start: a, end: b), rate: rate, outputStart: out, audible: speed.isAudible(rate: rate))
            pieces.append(p)
            out += p.outputDuration
        }
        var si = 0
        for k in kept {
            var t = k.start
            while si < segments.count, segments[si].range.end <= t { si += 1 }
            var j = si
            while t < k.end {
                if j < segments.count, segments[j].range.start < k.end {
                    let s = segments[j]
                    if s.range.start > t { add(t, s.range.start, 1); t = s.range.start }
                    let e = min(s.range.end, k.end)
                    add(t, e, s.rate)
                    t = e
                    if s.range.end <= k.end { j += 1 }
                } else {
                    add(t, k.end, 1)
                    t = k.end
                }
            }
            si = j
        }
        self.pieces = pieces
        self.duration = out
    }

    public init(manifest: ProjectManifest, edit: EditDocument) {
        self.init(duration: manifest.duration, trim: edit.trim, cuts: edit.cuts, speed: edit.speed)
    }

    /// Whether any piece plays at a speed other than 1.
    public var hasSpeedChanges: Bool { pieces.contains { $0.rate != 1 } }

    /// Index of the piece playing at output time `t` (clamped to the first/last piece).
    private func pieceIndex(forOutput t: Double) -> Int {
        var lo = 0, hi = pieces.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) >> 1
            if pieces[mid].outputStart <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Index of the last piece starting at or before source time `t`, or -1.
    private func pieceIndex(forSource t: Double) -> Int {
        var lo = 0, hi = pieces.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if pieces[mid].source.start <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    /// Source time for an output time (clamped to the output range).
    public func sourceTime(forOutput t: Double) -> Double {
        guard !pieces.isEmpty else { return 0 }
        let p = pieces[pieceIndex(forOutput: max(0, t))]
        let local = (max(0, t) - p.outputStart) * p.rate
        return min(p.source.end, p.source.start + max(0, local))
    }

    /// Output time for a source time, or `nil` if that moment was cut.
    public func outputTime(forSource t: Double) -> Double? {
        let i = pieceIndex(forSource: t)
        guard i >= 0 else { return nil }
        let p = pieces[i]
        guard p.source.contains(t) else { return nil }
        return p.outputStart + (t - p.source.start) / p.rate
    }

    /// Output time for a source time; a moment that was cut maps to where the output continues after it.
    public func nearestOutputTime(forSource t: Double) -> Double {
        if let o = outputTime(forSource: t) { return o }
        let i = pieceIndex(forSource: t)
        return i + 1 < pieces.count ? pieces[i + 1].outputStart : duration
    }

    /// Where a recording-time range plays on the output timeline: one output range per piece it touches.
    public func outputRanges(forSource r: TimeRange) -> [TimeRange] {
        var out: [TimeRange] = []
        for p in pieces where p.source.overlaps(r) {
            let a = max(r.start, p.source.start), b = min(r.end, p.source.end)
            let o = TimeRange(start: p.outputStart + (a - p.source.start) / p.rate, end: p.outputStart + (b - p.source.start) / p.rate)
            if let last = out.last, abs(last.end - o.start) < 1e-9 { out[out.count - 1].end = o.end } else { out.append(o) }
        }
        return out
    }

    /// The playback rate at output time `t`.
    public func rate(atOutput t: Double) -> Double {
        pieces.isEmpty ? 1 : pieces[pieceIndex(forOutput: t)].rate
    }
}
