import Foundation

/// One stretch of the recording played faster or slower. `range` is on the recording (source) timeline;
/// `EditTimeline` turns it into output time.
public struct SpeedSegment: Codable, Hashable, Sendable, Identifiable {
    /// Where a segment came from: added by hand, a "speed up typing" suggestion that was applied, or Clean Up.
    public enum Source: String, Codable, Hashable, Sendable { case user, typing, idle, cleanUp = "cleanup" }

    public var id: String
    public var range: TimeRange
    /// Playback rate, `SpeedSegment.minRate`…`maxRate` (2 = twice as fast).
    public var rate: Double
    public var source: Source

    public init(id: String = ShortID.make(length: 6), range: TimeRange, rate: Double, source: Source = .user) {
        self.id = id; self.range = range; self.rate = SpeedSegment.clampRate(rate); self.source = source
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ShortID.make(length: 6)
        range = try c.decode(TimeRange.self, forKey: .range)
        rate = SpeedSegment.clampRate(try c.decodeIfPresent(Double.self, forKey: .rate) ?? 1)
        // A source from a newer version reads as a segment added by hand.
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .user
    }

    public static let minRate = 0.25
    public static let maxRate = 8.0
    /// The rates the editor offers first.
    public static let presets: [Double] = [0.5, 1.5, 2, 4]
    /// Above this rate the sound of a segment is muted unless `SpeedSettings.keepFastAudio` is on.
    public static let audibleLimit = 2.0
    /// Shortest segment, in recording seconds.
    public static let minDuration = 0.1

    public static func clampRate(_ r: Double) -> Double {
        guard r.isFinite, r > 0 else { return 1 }
        return min(maxRate, max(minRate, r))
    }

    /// "2×", "1.5×", "0.25×".
    public static func label(_ rate: Double) -> String {
        var s = String(format: "%.2f", rate)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + "×"
    }

    /// Parses "2", "2x", "2×", "0.5X".
    public static func parseRate(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasSuffix("x") || t.hasSuffix("×") { t.removeLast() }
        guard let v = Double(t), v.isFinite, v > 0 else { return nil }
        return v
    }

    /// Recording seconds this segment removes from the output (negative when it slows down).
    public var savedSeconds: Double { range.duration - range.duration / rate }
}

/// `edit.json → speed`: speed segments and what happens to the sound of fast ones.
public struct SpeedSettings: Codable, Hashable, Sendable {
    /// Sorted by start, never overlapping, each at least `SpeedSegment.minDuration` long.
    public var segments: [SpeedSegment] = []
    /// Keep (pitch-preserved) sound in segments faster than 2×. Off: those stretches are silent.
    public var keepFastAudio = false

    public init(segments: [SpeedSegment] = [], keepFastAudio: Bool = false) {
        self.segments = SpeedSettings.normalized(segments)
        self.keepFastAudio = keepFastAudio
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // One unreadable segment is skipped, not the whole list.
        let lossy = (try? c.decodeIfPresent([Lossy].self, forKey: .segments)) ?? []
        segments = SpeedSettings.normalized(lossy.compactMap(\.value))
        keepFastAudio = try c.decodeIfPresent(Bool.self, forKey: .keepFastAudio) ?? false
    }

    public var isEmpty: Bool { segments.isEmpty }

    private struct Lossy: Decodable {
        let value: SpeedSegment?
        init(from decoder: any Decoder) throws { value = try? SpeedSegment(from: decoder) }
    }

    /// Sorted, valid, non-overlapping segments: where two overlap, the later one in the list wins the overlap
    /// (the earlier is trimmed or split around it). Rate-1 segments are dropped.
    public static func normalized(_ input: [SpeedSegment]) -> [SpeedSegment] {
        var out: [SpeedSegment] = []
        for var s in input {
            guard s.range.start.isFinite, s.range.end.isFinite else { continue }
            s.range = TimeRange(start: max(0, s.range.start), end: s.range.end)
            s.rate = SpeedSegment.clampRate(s.rate)
            guard s.range.duration >= SpeedSegment.minDuration else { continue }
            out = carve(out, s.range)
            if abs(s.rate - 1) > 1e-9 { out.append(s) }
        }
        return out.sorted { $0.range.start < $1.range.start }
    }

    /// `segments` with `range` removed (segments across it are trimmed or split; pieces too short are dropped).
    public static func carve(_ segments: [SpeedSegment], _ range: TimeRange) -> [SpeedSegment] {
        var out: [SpeedSegment] = []
        for s in segments {
            guard s.range.overlaps(range) else { out.append(s); continue }
            if range.start - s.range.start >= SpeedSegment.minDuration {
                var a = s
                a.range = TimeRange(start: s.range.start, end: range.start)
                out.append(a)
            }
            if s.range.end - range.end >= SpeedSegment.minDuration {
                var b = s
                b.range = TimeRange(start: range.end, end: s.range.end)
                if out.contains(where: { $0.id == b.id }) { b.id = ShortID.make(length: 6) }
                out.append(b)
            }
        }
        return out
    }

    /// Sets `range` to `rate` (1 = normal speed: removes speed there), replacing what overlapped it.
    public mutating func set(_ range: TimeRange, rate: Double, source: SpeedSegment.Source = .user, id: String? = nil) {
        var all = SpeedSettings.carve(segments, range)
        if abs(SpeedSegment.clampRate(rate) - 1) > 1e-9, range.duration >= SpeedSegment.minDuration {
            all.append(SpeedSegment(id: id ?? ShortID.make(length: 6), range: range, rate: rate, source: source))
        }
        segments = SpeedSettings.normalized(all)
    }

    /// The rate at recording time `t` (1 outside every segment).
    public func rate(at t: Double) -> Double { segments.first { $0.range.contains(t) }?.rate ?? 1 }

    /// Whether the sound of a segment at `rate` plays.
    public func isAudible(rate: Double) -> Bool { keepFastAudio || rate <= SpeedSegment.audibleLimit + 1e-9 }
}

// MARK: - Suggestions

/// A suggested speed-up: a stretch of continuous typing, or a long idle stretch (no input and no sound).
public struct SpeedSuggestion: Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case typing, idle }
    public var kind: Kind
    public var range: TimeRange
    public var rate: Double
    public init(kind: Kind, range: TimeRange, rate: Double) { self.kind = kind; self.range = range; self.rate = rate }

    /// Output seconds this saves.
    public var savedSeconds: Double { range.duration - range.duration / rate }

    public var segment: SpeedSegment {
        SpeedSegment(range: range, rate: rate, source: kind == .typing ? .typing : .idle)
    }
}

/// Finds "speed up typing" suggestions from the event log and the audio's silences. Pure and deterministic.
public enum SpeedSuggester {
    public struct Options: Hashable, Sendable {
        /// Shortest typing stretch worth speeding up (seconds, first key to last).
        public var minTyping = 3.0
        /// Longest gap between two key presses inside one typing stretch. 2 s keeps a burst with short thinking
        /// pauses as one segment instead of many (users of other tools complain about "too many cuts").
        public var maxKeyGap = 2.0
        /// Rate for typing with no speech over it.
        public var typingRate = 4.0
        /// Rate for typing over speech: 2× keeps the voice (pitch-preserved) audible.
        public var talkingTypingRate = 2.0
        /// Share of a typing stretch with speech over it that counts as talking.
        public var talkingShare = 0.25
        /// Shortest idle stretch (no input and silence) worth speeding up.
        public var minIdle = 4.0
        public var idleRate = 8.0
        /// Normal-speed air left at both ends of an idle stretch, so it doesn't start or stop abruptly.
        public var idleMargin = 0.4
        /// Pointer moves smaller than this (normalized) aren't input (sensor jitter).
        public var moveEpsilon = 0.002
        public init() {}
    }

    /// Suggestions in recording time, sorted. `silences` are silent ranges of the voice on the recording
    /// timeline (`nil`: no audio track, so everything counts as silent). Parts that are trimmed, cut or already
    /// have a speed are left out.
    public static func suggest(events: [InputEvent], silences: [TimeRange]?, duration: Double, edit: EditDocument,
                               options o: Options = Options()) -> [SpeedSuggestion] {
        let kept = EditTimeline(duration: duration, trim: edit.trim, cuts: edit.cuts).kept
        let taken = edit.speed.segments.map(\.range)
        let sorted = events.sorted { $0.t < $1.t }
        let speech = complement(silences, duration: duration)

        var out: [SpeedSuggestion] = []
        // Typing: runs of key presses no more than maxKeyGap apart.
        let keys = sorted.filter { $0.type == .key }.map(\.t)
        var i = 0
        while i < keys.count {
            var j = i
            while j + 1 < keys.count, keys[j + 1] - keys[j] <= o.maxKeyGap { j += 1 }
            let run = TimeRange(start: keys[i], end: min(duration, keys[j] + 0.15))
            if run.duration >= o.minTyping {
                let talking = overlap(speech, run) >= o.talkingShare * run.duration
                out.append(SpeedSuggestion(kind: .typing, range: run, rate: talking ? o.talkingTypingRate : o.typingRate))
            }
            i = j + 1
        }
        // Idle: silence with no input (clicks, scrolls, keys, real pointer moves) across it.
        var inputTimes: [Double] = []
        var last: NormPoint?
        for e in sorted {
            switch e.type {
            case .down, .up, .scroll, .key: inputTimes.append(e.t)
            case .move:
                if let p = e.point {
                    if let l = last, abs(p.x - l.x) < o.moveEpsilon, abs(p.y - l.y) < o.moveEpsilon { continue }
                    if last != nil { inputTimes.append(e.t) }
                    last = p
                }
            default: break
            }
        }
        let quiet = silences ?? [TimeRange(start: 0, end: duration)]
        for s in quiet {
            var start = s.start
            let inside = inputTimes.filter { $0 >= s.start && $0 < s.end }
            for t in inside + [s.end] {
                let gap = TimeRange(start: start + o.idleMargin, end: min(t, duration) - o.idleMargin)
                if t - start >= o.minIdle {
                    out.append(SpeedSuggestion(kind: .idle, range: gap, rate: o.idleRate))
                }
                start = t
            }
        }
        // Typing wins over idle where they meet; then keep only what is in the output and has no speed yet.
        out.sort { $0.range.start < $1.range.start }
        var result: [SpeedSuggestion] = []
        for s in out {
            var pieces = intersect([s.range], kept)
            for t in taken { pieces = subtract(pieces, t) }
            if s.kind == .idle { for t in out where t.kind == .typing { pieces = subtract(pieces, t.range) } }
            let minimum = s.kind == .typing ? o.minTyping * 0.5 : o.minIdle * 0.5
            for p in pieces where p.duration >= minimum {
                result.append(SpeedSuggestion(kind: s.kind, range: p, rate: s.rate))
            }
        }
        return result.sorted { $0.range.start < $1.range.start }
    }

    /// "Speed up 6 typing stretches, saves 0:24" style summary pieces: counts per kind and seconds saved.
    public static func summary(_ s: [SpeedSuggestion]) -> (typing: Int, idle: Int, saved: Double) {
        (s.filter { $0.kind == .typing }.count, s.filter { $0.kind == .idle }.count, s.reduce(0) { $0 + $1.savedSeconds })
    }

    // MARK: Range maths

    static func complement(_ silences: [TimeRange]?, duration: Double) -> [TimeRange] {
        guard let silences else { return [] }
        return subtractAll([TimeRange(start: 0, end: duration)], silences)
    }

    static func overlap(_ ranges: [TimeRange], _ r: TimeRange) -> Double {
        ranges.reduce(0) { $0 + max(0, min($1.end, r.end) - max($1.start, r.start)) }
    }

    static func intersect(_ a: [TimeRange], _ b: [TimeRange]) -> [TimeRange] {
        var out: [TimeRange] = []
        for x in a { for y in b where x.overlaps(y) { out.append(TimeRange(start: max(x.start, y.start), end: min(x.end, y.end))) } }
        return out
    }

    static func subtract(_ a: [TimeRange], _ cut: TimeRange) -> [TimeRange] {
        var out: [TimeRange] = []
        for r in a {
            guard r.overlaps(cut) else { out.append(r); continue }
            if cut.start > r.start { out.append(TimeRange(start: r.start, end: cut.start)) }
            if cut.end < r.end { out.append(TimeRange(start: cut.end, end: r.end)) }
        }
        return out
    }

    static func subtractAll(_ a: [TimeRange], _ cuts: [TimeRange]) -> [TimeRange] {
        cuts.reduce(a) { subtract($0, $1) }
    }
}
