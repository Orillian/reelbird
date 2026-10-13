import Foundation

/// A stretch of the recording where the screen and the camera share the frame in another way than the
/// overlay bubble: the camera fills the frame, the two sit side by side (stacked on a tall canvas), or only
/// the screen shows. `edit.json → layouts`, on the recording timeline. Outside every segment the camera is the
/// overlay bubble (`EditDocument.camera`).
public struct LayoutSegment: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        /// The camera bubble over the screen (the default outside segments).
        case overlay
        /// The camera fills the frame, cropped around its centre.
        case fullCamera
        /// Screen and camera side by side (stacked on a canvas taller than wide), on the background.
        case split
        /// The screen alone: the camera steps away.
        case screenOnly

        public var title: String {
            switch self {
            case .overlay: "Overlay"
            case .fullCamera: "Camera"
            case .split: "Split"
            case .screenOnly: "Screen"
            }
        }
    }

    public var id: String
    public var range: TimeRange
    public var kind: Kind

    public init(id: String = ShortID.make(length: 6), range: TimeRange, kind: Kind) {
        self.id = id; self.range = range; self.kind = kind
    }

    /// The shortest segment kept (seconds).
    public static let minimumLength = 0.2

    /// Segments cleaned for use: finite, start ≥ 0, at least `minimumLength` long, sorted by start, an overlap
    /// ending where the next one starts.
    public static func normalized(_ segments: [LayoutSegment]) -> [LayoutSegment] {
        var out = segments.filter { $0.range.start.isFinite && $0.range.end.isFinite }
            .map { s -> LayoutSegment in
                var s = s
                s.range = TimeRange(start: max(0, s.range.start), end: s.range.end)
                return s
            }
            .filter { $0.range.duration >= minimumLength }
            .sorted { ($0.range.start, $0.id) < ($1.range.start, $1.id) }
        var i = 1
        while i < out.count {
            if out[i].range.start < out[i - 1].range.end {
                out[i - 1].range.end = out[i].range.start
                if out[i - 1].range.duration < minimumLength { out.remove(at: i - 1); continue }
            }
            i += 1
        }
        return out
    }

    /// `segments` with `new` laid over them: the parts of others it overlaps give way (a segment it falls inside
    /// is split around it). An `overlay` segment just clears its range.
    public static func inserting(_ new: LayoutSegment, into segments: [LayoutSegment]) -> [LayoutSegment] {
        var out: [LayoutSegment] = []
        for s in normalized(segments) {
            guard s.range.overlaps(new.range) else { out.append(s); continue }
            if new.range.start - s.range.start >= minimumLength {
                out.append(LayoutSegment(id: s.id, range: TimeRange(start: s.range.start, end: new.range.start), kind: s.kind))
            }
            if s.range.end - new.range.end >= minimumLength {
                out.append(LayoutSegment(range: TimeRange(start: new.range.end, end: s.range.end), kind: s.kind))
            }
        }
        if new.kind != .overlay { out.append(new) }
        return normalized(out)
    }

    /// The layouts switched with the layout shortcut while recording: the `layout` of the `camera` events, one
    /// segment per stretch that wasn't the overlay, up to the next switch or `duration`.
    public static func segments(fromLive events: [InputEvent], duration: Double) -> [LayoutSegment] {
        var out: [LayoutSegment] = []
        var current: (kind: Kind, since: Double) = (.overlay, 0)
        func close(at t: Double) {
            guard current.kind != .overlay, t - current.since >= minimumLength else { return }
            out.append(LayoutSegment(range: TimeRange(start: current.since, end: t), kind: current.kind))
        }
        for e in events where e.type == .camera {
            guard let raw = e.layout, let kind = Kind(rawValue: raw), kind != current.kind, e.t.isFinite else { continue }
            close(at: e.t)
            current = (kind, max(0, e.t))
        }
        let end = duration.isFinite && duration > 0 ? duration : (events.last?.t ?? 0)
        close(at: end)
        return normalized(out)
    }
}

/// The layout over recording time: which layout shows, and the springy change from one to the next. A change
/// takes `transitionDuration`, centred on the segment's edge (shorter between edges closer than that), except a
/// segment starting at 0 or ending at the end of the recording, which is there from the first or to the last
/// frame. Built once; `state(at:)` allocates nothing.
public struct LayoutTimeline: Hashable, Sendable {
    /// How long a change of layout takes (seconds).
    public static let transitionDuration = 0.5

    public struct State: Hashable, Sendable {
        public var from: LayoutSegment.Kind
        public var to: LayoutSegment.Kind
        /// 0 = `from`, 1 = `to`, on the spring curve (may be the same kind when steady).
        public var progress: Double

        public static let overlay = State(from: .overlay, to: .overlay, progress: 1)
        public var isSteady: Bool { from == to || progress >= 1 }
        /// The layout that dominates now.
        public var kind: LayoutSegment.Kind { progress >= 0.5 ? to : from }
        /// How much of `kind` is in the frame (0...1).
        public func weight(_ k: LayoutSegment.Kind) -> Double {
            (from == k ? 1 - progress : 0) + (to == k ? progress : 0)
        }
    }

    let t0: [Double]
    let t1: [Double]
    let from: [LayoutSegment.Kind]
    let to: [LayoutSegment.Kind]

    public init(_ segments: [LayoutSegment], duration: Double = .infinity) {
        let segs = LayoutSegment.normalized(segments)
        // Edges where the layout changes.
        var edges: [(t: Double, from: LayoutSegment.Kind, to: LayoutSegment.Kind)] = []
        var cur = LayoutSegment.Kind.overlay, curEnd = 0.0
        for s in segs {
            if s.range.start > curEnd + 1e-6, cur != .overlay { edges.append((curEnd, cur, .overlay)); cur = .overlay }
            if s.kind != cur { edges.append((s.range.start, cur, s.kind)) }
            cur = s.kind
            curEnd = s.range.end
        }
        if cur != .overlay { edges.append((curEnd, cur, .overlay)) }
        let end = duration.isFinite && duration > 0 ? duration : .infinity
        var t0: [Double] = [], t1: [Double] = [], from: [LayoutSegment.Kind] = [], to: [LayoutSegment.Kind] = []
        for (i, e) in edges.enumerated() {
            if e.t >= end - 1e-6 { continue } // ends with the recording: stays to the last frame
            var half = Self.transitionDuration / 2
            if i > 0 { half = min(half, (e.t - edges[i - 1].t) / 2) }
            if i + 1 < edges.count { half = min(half, (edges[i + 1].t - e.t) / 2) }
            half = min(half, max(0, e.t)) // starts at 0: there from the first frame
            if end.isFinite { half = min(half, max(0, end - e.t)) }
            t0.append(e.t - half); t1.append(e.t + half); from.append(e.from); to.append(e.to)
        }
        self.t0 = t0; self.t1 = t1; self.from = from; self.to = to
    }

    /// Whether the layout never leaves the overlay.
    public var isEmpty: Bool { t0.isEmpty }

    public func state(at t: Double) -> State {
        var lo = 0, hi = t0.count
        while lo < hi { let m = (lo + hi) >> 1; if t0[m] <= t { lo = m + 1 } else { hi = m } }
        let i = lo - 1
        guard i >= 0 else { return .overlay }
        let span = t1[i] - t0[i]
        if t >= t1[i] || span <= 1e-9 { return State(from: to[i], to: to[i], progress: 1) }
        return State(from: from[i], to: to[i], progress: Self.ease((t - t0[i]) / span))
    }

    /// The layout change's curve: a critically damped spring from rest (fast start, soft landing, no overshoot).
    public static func ease(_ u: Double) -> Double { Spring.ease(u, omegaT: 6) }
}

extension EditDocument {
    /// The layout over time.
    public func layoutTimeline(duration: Double) -> LayoutTimeline { LayoutTimeline(layouts, duration: duration) }
}

/// Decodes a value or nothing, so one unreadable element doesn't fail a whole list.
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}
