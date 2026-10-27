import Foundation

// Clean Up: one deliberate pass that shortens long pauses, removes "um"/"uh", trims dead time at the start and
// end, speeds up silent stretches where something happens on screen, and finds retakes. The planner here is
// pure and deterministic; `ReelbirdAI.CleanUpAnalyzer` reads the audio, events and screen it needs.
// Defaults come from research/2026-10-27-reelbird-auto-edit/04-cleanup-implementation.md.

/// The audio level of the voice over the recording, in 20 ms windows (dBFS), for cut placement and filler checks.
public struct AudioEnvelope: Hashable, Sendable {
    public var levels: [Float]
    /// Window length in seconds.
    public var window: Double
    /// Recording time of the first window's start.
    public var origin: Double

    public init(levels: [Float], window: Double = 0.02, origin: Double = 0) {
        self.levels = levels; self.window = window; self.origin = origin
    }

    /// Level of the window holding recording time `t` (-160 outside the audio).
    public func level(at t: Double) -> Float {
        let i = Int(((t - origin) / window).rounded(.down))
        return i >= 0 && i < levels.count ? levels[i] : -160
    }

    /// Window indices covering `r`, clamped to the audio.
    func indices(_ r: TimeRange) -> Range<Int> {
        let a = max(0, Int(((r.start - origin) / window).rounded(.down)))
        let b = min(levels.count, Int(((r.end - origin) / window).rounded(.up)))
        return a < b ? a..<b : a..<a
    }

    /// The room's noise floor: the 10th percentile of the levels above digital silence.
    public var noiseFloor: Float {
        let real = levels.filter { $0 > -120 }.sorted()
        guard !real.isEmpty else { return -90 }
        return real[min(real.count - 1, real.count / 10)]
    }

    /// The silence threshold for this room: noise floor + `margin` dB, kept between -60 and -30 dBFS.
    public func adaptiveThreshold(margin: Float = 7) -> Float { min(-30, max(-60, noiseFloor + margin)) }

    /// Share of the windows in `r` below `threshold` (1 when `r` has no windows).
    func quietShare(_ r: TimeRange, threshold: Float) -> Double {
        let idx = indices(r)
        guard !idx.isEmpty else { return 1 }
        return Double(idx.filter { levels[$0] < threshold }.count) / Double(idx.count)
    }

    /// The middle of the quietest window inside `r`, or `nil` when `r` holds no window.
    public func quietest(in r: TimeRange) -> Double? {
        let idx = indices(r)
        guard let best = idx.min(by: { levels[$0] < levels[$1] }) else { return nil }
        return origin + (Double(best) + 0.5) * window
    }
}

/// How much the screen changed between samples, from small greyscale thumbnails. `change` is the mean absolute
/// difference to the previous sample, 0...1.
public struct ScreenChange: Hashable, Sendable {
    public var t: Double
    public var change: Double
    public init(t: Double, change: Double) { self.t = t; self.change = change }
}

/// Everything the planner reads. Times are on the recording timeline.
public struct CleanUpInputs: Hashable, Sendable {
    /// A recognised word with its time range (punctuation attached, as the transcript has it).
    public struct Word: Hashable, Sendable {
        public var range: TimeRange
        public var text: String
        public init(range: TimeRange, text: String) { self.range = range; self.text = text }
    }

    public var duration: Double
    /// Words in order. Empty: no transcript (pauses then come from the audio level alone; no fillers or retakes).
    public var words: [Word]
    public var events: [InputEvent]
    /// The voice's level. `nil`: no microphone track.
    public var envelope: AudioEnvelope?
    /// Screen change samples, sorted. `nil`: not measured (input events alone decide what is activity).
    public var screen: [ScreenChange]?
    /// Frame rate cuts are snapped to.
    public var frameRate: Double

    public init(duration: Double, words: [Word] = [], events: [InputEvent] = [], envelope: AudioEnvelope? = nil,
                screen: [ScreenChange]? = nil, frameRate: Double = 60) {
        self.duration = duration; self.words = words; self.events = events; self.envelope = envelope
        self.screen = screen; self.frameRate = frameRate > 0 ? frameRate : 60
    }
}

/// One thing Clean Up found: applied to the edit, or a suggestion waiting for the person.
public struct CleanUpItem: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case pause, filler, retake, deadStart, deadEnd, speedUp

        /// "pause", "um", "retake", …, for summaries.
        public var label: String {
            switch self {
            case .pause: "pause"
            case .filler: "um"
            case .retake: "retake"
            case .deadStart: "dead start"
            case .deadEnd: "dead end"
            case .speedUp: "speed-up"
            }
        }
    }

    /// Stable for the same finding: kind and start time.
    public var id: String
    public var kind: Kind
    /// What was found, on the recording timeline: the whole pause, the filler's sound, the earlier take, the dead
    /// stretch, or the stretch that is sped up.
    public var range: TimeRange
    /// The cut it makes (recording time); `nil` for a speed-up.
    public var cut: TimeRange?
    /// A speed-up's rate.
    public var rate: Double?
    /// The speed segment a speed-up added, once applied.
    public var speedID: String?
    /// Why, in words: "pause 1.8 s → 0.45 s", "um", "retake: kept the later take".
    public var reason: String
    /// 0...1. Items below `CleanUp.Options.applyConfidence` arrive as suggestions.
    public var confidence: Double

    public init(id: String? = nil, kind: Kind, range: TimeRange, cut: TimeRange? = nil, rate: Double? = nil,
                speedID: String? = nil, reason: String, confidence: Double) {
        self.id = id ?? "\(kind.rawValue)-\(Int((range.start * 1000).rounded()))"
        self.kind = kind; self.range = range; self.cut = cut; self.rate = rate; self.speedID = speedID
        self.reason = reason; self.confidence = min(1, max(0, confidence))
    }

    /// Output seconds this saves (cut length, or what the speed-up removes).
    public var savedSeconds: Double {
        if let cut { return cut.duration }
        if let rate, rate > 0 { return range.duration - range.duration / rate }
        return 0
    }

    /// The recording time the edit touches: the cut, or the sped-up stretch.
    public var editRange: TimeRange { cut ?? range }
}

/// `edit.json → cleanUp`: what Clean Up did, so one pass can be undone, one item restored, and a later run adds
/// only new finds. Items' cuts are in `EditDocument.cuts` and their speed-ups in `speed` (source `cleanup`);
/// a cut or speed segment the person changed by hand no longer matches and is left alone.
public struct CleanUpRecord: Codable, Hashable, Sendable {
    /// What a person put back or dismissed. A later run skips findings of the same kind that overlap it.
    public struct Restored: Codable, Hashable, Sendable {
        public var kind: CleanUpItem.Kind
        public var range: TimeRange
        public init(kind: CleanUpItem.Kind, range: TimeRange) { self.kind = kind; self.range = range }
    }

    /// Items whose cut or speed-up is in the edit.
    public var applied: [CleanUpItem] = []
    /// Suggestions from the last run, not in the edit.
    public var suggestions: [CleanUpItem] = []
    public var restored: [Restored] = []

    public init(applied: [CleanUpItem] = [], suggestions: [CleanUpItem] = [], restored: [Restored] = []) {
        self.applied = applied; self.suggestions = suggestions; self.restored = restored
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An item this version can't read (a newer kind) is skipped, not the whole record.
        applied = ((try? c.decodeIfPresent([Lenient<CleanUpItem>].self, forKey: .applied)) ?? nil)?.compactMap(\.value) ?? []
        suggestions = ((try? c.decodeIfPresent([Lenient<CleanUpItem>].self, forKey: .suggestions)) ?? nil)?.compactMap(\.value) ?? []
        restored = ((try? c.decodeIfPresent([Lenient<Restored>].self, forKey: .restored)) ?? nil)?.compactMap(\.value) ?? []
    }

    public var isEmpty: Bool { applied.isEmpty && suggestions.isEmpty && restored.isEmpty }
}

/// The result of one planning run.
public struct CleanUpReport: Hashable, Sendable {
    /// Findings confident enough to apply, sorted by time.
    public var applied: [CleanUpItem]
    /// Findings left for the person to accept, sorted by time.
    public var suggestions: [CleanUpItem]

    public init(applied: [CleanUpItem] = [], suggestions: [CleanUpItem] = []) {
        self.applied = applied; self.suggestions = suggestions
    }

    public var isEmpty: Bool { applied.isEmpty && suggestions.isEmpty }
    /// Output seconds the applied items save.
    public var savedSeconds: Double { applied.reduce(0) { $0 + $1.savedSeconds } }
    /// Applied items per kind.
    public func count(_ kind: CleanUpItem.Kind) -> Int { applied.filter { $0.kind == kind }.count }
}

public enum CleanUp {
    public struct Options: Hashable, Sendable {
        /// Silent gaps between words at least this long are shortened.
        public var minPause = 0.75
        /// Kept pause: clamp(base + perSecond × (gap − minPause), base, maxKept), plus `sentenceExtra` after . ? !
        public var keptBase = 0.35
        public var keptPerSecond = 0.1
        public var maxKept = 0.8
        public var sentenceExtra = 0.1
        /// Air always kept after the last word and before the next one.
        public var minLead = 0.15
        public var minTail = 0.1
        /// Shorter cuts aren't worth a join.
        public var minCut = 0.25
        /// No cut within this many seconds of a click, key or scroll.
        public var inputGuard = 0.4
        /// Silent stretches with activity shorter than this are left alone; longer ones are sped up.
        public var minActiveSpeedUp = 2.0
        /// Speed for silent stretches with clicks, scrolls or a changing screen; with pointer moves only.
        public var activeRate = 3.0
        public var movingRate = 2.0
        /// Normal-speed air at both ends of a sped-up silent stretch.
        public var speedMargin = 0.3
        /// Mean thumbnail difference above which the screen counts as changing.
        public var screenChange = 0.02
        /// Typing speed-ups (see `SpeedSuggester`); typing under speech at most 1.5×.
        public var typing = SpeedSuggester.Options()
        /// Dead start: cut up to this long before the first speech / first input.
        public var leadBeforeSpeech = 0.3
        public var leadBeforeInput = 0.5
        /// Dead end: kept after the last speech or action.
        public var tail = 0.6
        /// Dead stretches shorter than this are left alone.
        public var minDead = 0.75
        /// Input in the first/last this many seconds is the record click or the stop shortcut, not content.
        public var ignoreInputAtStart = 0.3
        public var ignoreInputAtEnd = 1.5
        /// Items at least this confident are applied; the rest are suggestions.
        public var applyConfidence = 0.8
        /// Retake search: phrases split at gaps this long; a later take within this many seconds.
        public var phraseGap = 0.5
        public var retakeWindow = 45.0
        public var retakeSimilarity = 0.6

        public init() {
            typing.talkingTypingRate = 1.5
            typing.maxKeyGap = 2.0
        }
    }

    // MARK: - Plan

    /// Finds what to clean up. Parts already cut or trimmed, speed segments, findings already applied and
    /// anything the person restored or dismissed (`edit.cleanUp.restored`) are left out.
    public static func plan(_ input: CleanUpInputs, edit: EditDocument, options o: Options = Options()) -> CleanUpReport {
        let ctx = Context(input: input, edit: edit, options: o)
        var found: [CleanUpItem] = []
        found += deadEnds(ctx)
        found += retakes(ctx)
        found += typing(ctx)
        found += pauses(ctx)
        found += fillers(ctx)

        // Drop findings a person restored or dismissed, already applied ones, and any that touch a part already
        // cut or a stretch with a speed. Then confident findings go first, earlier kinds winning an overlap;
        // suggestions only fill what's left, so a doubtful retake never blocks the pauses inside it.
        let previous = edit.cleanUp.applied
        let candidates = found.filter { item in
            let r = item.editRange
            guard r.duration > 0.01, ctx.isKept(r) else { return false }
            if previous.contains(where: { $0.editRange.overlaps(r) }) { return false }
            if edit.cleanUp.restored.contains(where: { $0.kind == item.kind && $0.range.overlaps(item.range) }) { return false }
            if item.kind == .speedUp, edit.speed.segments.contains(where: { $0.range.overlaps(r) }) { return false }
            return true
        }
        var applied: [CleanUpItem] = []
        for item in candidates where item.confidence >= o.applyConfidence {
            if !applied.contains(where: { $0.editRange.overlaps(item.editRange) }) { applied.append(item) }
        }
        var suggestions: [CleanUpItem] = []
        for item in candidates where item.confidence < o.applyConfidence {
            let r = item.editRange
            if !applied.contains(where: { $0.editRange.overlaps(r) && $0.kind != .pause })
                && !suggestions.contains(where: { $0.editRange.overlaps(r) }) { suggestions.append(item) }
        }
        applied.sort { $0.range.start < $1.range.start }
        suggestions.sort { $0.range.start < $1.range.start }
        return CleanUpReport(applied: applied, suggestions: suggestions)
    }

    /// Shared lookups for one run.
    struct Context {
        let input: CleanUpInputs
        let edit: EditDocument
        let o: Options
        let kept: [TimeRange]
        /// Clicks, keys, scrolls and drags (mouse down to up), as ranges; record/stop input left out.
        let inputs: [TimeRange]
        /// Real pointer moves (not jitter).
        let moves: [Double]
        let keys: [Double]
        let threshold: Float

        init(input: CleanUpInputs, edit: EditDocument, options: Options) {
            self.input = input; self.edit = edit; self.o = options
            kept = EditTimeline(duration: input.duration, trim: edit.trim, cuts: edit.cuts).kept
            let lo = options.ignoreInputAtStart, hi = input.duration - options.ignoreInputAtEnd
            let sorted = input.events.sorted { $0.t < $1.t }
            var ranges: [TimeRange] = []
            var moves: [Double] = []
            var keys: [Double] = []
            var down: Double?
            var last: NormPoint?
            for e in sorted {
                let content = e.t >= lo && e.t <= hi
                switch e.type {
                case .down: down = e.t
                case .up:
                    let start = down ?? e.t
                    down = nil
                    if content || (start >= lo && start <= hi) { ranges.append(TimeRange(start: start, end: max(start, e.t))) }
                case .scroll: if content { ranges.append(TimeRange(start: e.t, end: e.t)) }
                case .key:
                    if content { ranges.append(TimeRange(start: e.t, end: e.t)); keys.append(e.t) }
                case .move:
                    if let p = e.point {
                        if let l = last, abs(p.x - l.x) < 0.002, abs(p.y - l.y) < 0.002 { continue }
                        if last != nil, content { moves.append(e.t) }
                        last = p
                    }
                default: break
                }
            }
            if let down, down >= lo, down <= hi { ranges.append(TimeRange(start: down, end: down)) }
            inputs = ranges; self.moves = moves; self.keys = keys
            threshold = input.envelope?.adaptiveThreshold() ?? -45
        }

        /// Whether all of `r` is still in the output.
        func isKept(_ r: TimeRange) -> Bool { kept.contains { $0.start <= r.start + 1e-6 && $0.end >= r.end - 1e-6 } }

        /// Whether a click, key, scroll or drag happens within `pad` seconds of `r`.
        func hasInput(near r: TimeRange, pad: Double) -> Bool {
            let wide = TimeRange(start: r.start - pad, end: r.end + pad)
            return inputs.contains { $0.start <= wide.end && $0.end >= wide.start }
        }

        func hasMoves(in r: TimeRange) -> Bool { moves.contains { $0 >= r.start && $0 <= r.end } }

        /// Whether the screen changes inside `r` (thumbnail difference over the threshold).
        func screenChanges(in r: TimeRange) -> Bool {
            guard let screen = input.screen else { return false }
            return screen.contains { $0.t > r.start && $0.t <= r.end && $0.change > o.screenChange }
        }

        /// Total screen change inside `r`, or `nil` when unmeasured.
        func screenChange(in r: TimeRange) -> Double? {
            guard let screen = input.screen, !screen.isEmpty else { return nil }
            return screen.filter { $0.t > r.start && $0.t <= r.end }.reduce(0) { $0 + $1.change }
        }

        /// `t` moved to the nearest frame boundary.
        func frameSnap(_ t: Double) -> Double {
            let f = input.frameRate
            return (t * f).rounded() / f
        }

        /// The quietest moment within `reach` of `t`, inside `bounds`.
        func quietPoint(near t: Double, reach: Double, bounds: TimeRange) -> Double {
            let r = TimeRange(start: max(bounds.start, t - reach), end: min(bounds.end, t + reach))
            guard r.duration > 0, let q = input.envelope?.quietest(in: r) else { return t }
            return q
        }

        /// Silent stretches for when there is no transcript: from the level, at least `min` long.
        func silences(min: Double) -> [TimeRange] {
            guard let env = input.envelope else { return [] }
            var out: [TimeRange] = []
            var start: Int?
            for i in 0...env.levels.count {
                let quiet = i < env.levels.count && env.levels[i] < threshold
                if quiet, start == nil { start = i }
                if !quiet, let s = start {
                    let r = TimeRange(start: env.origin + Double(s) * env.window, end: env.origin + Double(i) * env.window)
                    if r.duration >= min { out.append(r) }
                    start = nil
                }
            }
            return out
        }

        /// The voice's speech: word ranges, or the complement of the silences when there is no transcript.
        var speech: [TimeRange] {
            if !input.words.isEmpty { return input.words.map(\.range) }
            guard let env = input.envelope, !env.levels.isEmpty else { return [] }
            // Only where there is audio: before and after the voice track nobody speaks.
            let span = TimeRange(start: env.origin, end: env.origin + Double(env.levels.count) * env.window)
            return SpeedSuggester.subtractAll([span], silences(min: 0.3)).filter { $0.duration >= 0.1 }
        }
    }

    // MARK: Dead start and end

    static func deadEnds(_ c: Context) -> [CleanUpItem] {
        let o = c.o
        let speech = c.speech
        let content = c.inputs.filter { $0.start >= o.ignoreInputAtStart }
        let firstSpeech = speech.first?.start, lastSpeech = speech.last?.end
        let firstInput = content.first?.start, lastInput = content.map(\.end).max()
        guard firstSpeech != nil || firstInput != nil else { return [] }
        let base = c.kept.first?.start ?? 0
        let baseEnd = c.kept.last?.end ?? c.input.duration
        var out: [CleanUpItem] = []
        let start = min(firstSpeech.map { $0 - o.leadBeforeSpeech } ?? .infinity, firstInput.map { $0 - o.leadBeforeInput } ?? .infinity)
        if start - base >= o.minDead {
            let cut = TimeRange(start: base, end: c.frameSnap(start))
            out.append(CleanUpItem(kind: .deadStart, range: cut, cut: cut,
                                   reason: "dead start \(seconds(cut.duration)) before you begin", confidence: 0.95))
        }
        let end = max(lastSpeech.map { $0 + o.tail } ?? -.infinity, lastInput.map { $0 + o.tail } ?? -.infinity)
        if baseEnd - end >= o.minDead {
            let cut = TimeRange(start: c.frameSnap(end), end: baseEnd)
            out.append(CleanUpItem(kind: .deadEnd, range: cut, cut: cut,
                                   reason: "dead end \(seconds(cut.duration)) after you finish", confidence: 0.95))
        }
        return out
    }

    // MARK: Pauses

    static func pauses(_ c: Context) -> [CleanUpItem] {
        let o = c.o
        // Gaps between words (or silences from the level with no transcript), with whether a sentence ends before.
        var gaps: [(range: TimeRange, sentenceEnd: Bool)] = []
        let words = c.input.words
        if words.isEmpty {
            gaps = c.silences(min: o.minPause).map { ($0, false) }
        } else {
            for i in 0..<(words.count - 1) {
                let a = words[i].range.end, b = words[i + 1].range.start
                guard b - a >= o.minPause else { continue }
                gaps.append((TimeRange(start: a, end: b), endsSentence(words[i].text)))
            }
        }
        var out: [CleanUpItem] = []
        for (gap, sentenceEnd) in gaps {
            // A gap that isn't quiet (music, someone else talking) is left alone.
            if let env = c.input.envelope, env.quietShare(gap, threshold: c.threshold) < 0.6 { continue }
            let active = c.hasInput(near: gap, pad: 0) || c.screenChanges(in: gap) || c.hasMoves(in: gap)
            if active {
                guard gap.duration >= o.minActiveSpeedUp else { continue }
                // Typing is handled by the typing speed-ups; this is clicking, scrolling, loading or moving about.
                let r = TimeRange(start: gap.start + o.speedMargin, end: gap.end - o.speedMargin)
                let busy = c.hasInput(near: gap, pad: 0) || c.screenChanges(in: gap)
                let rate = busy ? o.activeRate : o.movingRate
                out.append(CleanUpItem(kind: .speedUp, range: r, rate: rate,
                                       reason: "silent \(seconds(gap.duration)) while \(busy ? "the screen changes" : "the pointer moves"), \(SpeedSegment.label(rate))",
                                       confidence: 0.85))
                continue
            }
            let keep = min(o.maxKept, max(o.keptBase, o.keptBase + o.keptPerSecond * (gap.duration - o.minPause)))
                + (sentenceEnd ? o.sentenceExtra : 0)
            guard gap.duration - keep >= o.minCut else { continue }
            let lead = max(o.minLead, keep * 0.55), tail = max(o.minTail, keep - lead)
            // Each edge moves to the quietest 20 ms nearby, never into the air kept next to speech.
            let inner = TimeRange(start: gap.start + o.minLead, end: gap.end - o.minTail)
            var a = c.quietPoint(near: gap.start + lead, reach: 0.06, bounds: inner)
            var b = c.quietPoint(near: gap.end - tail, reach: 0.06, bounds: inner)
            a = c.frameSnap(a); b = c.frameSnap(b)
            guard b - a >= o.minCut else { continue }
            var cut = TimeRange(start: a, end: b)
            // Keep clear of clicks and keys just outside the gap.
            for i in c.inputs {
                if i.end <= cut.start, cut.start - i.end < o.inputGuard { cut.start = c.frameSnap(i.end + o.inputGuard) }
                if i.start >= cut.end, i.start - cut.end < o.inputGuard { cut.end = c.frameSnap(i.start - o.inputGuard) }
            }
            guard cut.duration >= o.minCut else { continue }
            out.append(CleanUpItem(kind: .pause, range: gap, cut: cut,
                                   reason: "pause \(seconds(gap.duration)) → \(seconds(gap.duration - cut.duration))",
                                   confidence: 0.9))
        }
        return out
    }

    // MARK: Typing

    static func typing(_ c: Context) -> [CleanUpItem] {
        let silences: [TimeRange]? = c.input.words.isEmpty && c.input.envelope == nil ? nil
            : SpeedSuggester.subtractAll([TimeRange(start: 0, end: c.input.duration)], c.speech)
        let found = SpeedSuggester.suggest(events: c.input.events, silences: silences, duration: c.input.duration,
                                           edit: c.edit, options: c.o.typing)
        return found.filter { $0.kind == .typing }.map { s in
            CleanUpItem(kind: .speedUp, range: s.range, rate: s.rate,
                        reason: "typing \(seconds(s.range.duration)), \(SpeedSegment.label(s.rate))", confidence: 0.9)
        }
    }

    // MARK: Fillers

    /// Words that are never cut as fillers.
    static let neverFillers: Set<String> = ["like", "so", "well", "you", "know", "i", "a", "and", "but", "right", "okay", "ok"]

    /// "um" and "uh". Apple's recogniser drops them and folds their time into the next word, so look for a word
    /// that is too long for its letters and starts with its own voiced island, cut off from the word by a dip.
    static func fillers(_ c: Context) -> [CleanUpItem] {
        guard let env = c.input.envelope else { return [] }
        let words = c.input.words
        var out: [CleanUpItem] = []
        for (i, w) in words.enumerated() {
            let plain = normalize(w.text)
            guard !plain.isEmpty, !neverFillers.contains(plain) else { continue }
            let expected = 0.2 * Double(syllables(plain))
            guard w.range.duration > max(0.55, 2.2 * expected) else { continue }
            guard let island = FillerIsland.find(in: w.range, envelope: env, threshold: c.threshold) else { continue }
            // The real word needs room after the island.
            guard w.range.end - island.dip.end >= 0.6 * expected else { continue }
            var confidence = 0.55
            if island.depth >= 15 { confidence += 0.15 } else if island.depth >= 10 { confidence += 0.08 }
            if w.range.duration > 3 * expected { confidence += 0.1 }
            // Both edges in quiet: before the island (the gap before the word) and the dip itself.
            let before = TimeRange(start: island.voice.start - 0.06, end: island.voice.start)
            let prevEnd = i > 0 ? words[i - 1].range.end : -1
            let quietBefore = env.quietShare(before, threshold: c.threshold) >= 0.66 && island.voice.start - prevEnd >= 0.04
            if quietBefore { confidence += 0.1 }
            if island.dipQuiet { confidence += 0.05 }
            if !quietBefore || !island.dipQuiet { confidence = min(confidence, 0.75) }
            let start = c.frameSnap(max(prevEnd + 0.02, island.voice.start - 0.02))
            let end = c.frameSnap(island.dip.start + island.dip.duration * 0.6)
            guard end - start >= 0.1 else { continue }
            let cut = TimeRange(start: start, end: end)
            if c.hasInput(near: cut, pad: c.o.inputGuard) { confidence = min(confidence, 0.7) }
            out.append(CleanUpItem(kind: .filler, range: island.voice, cut: cut,
                                   reason: "um before “\(w.text)”", confidence: confidence))
        }
        return out
    }

    // MARK: Retakes

    /// Cue phrases that say the next words replace the last ones.
    static let cues = ["sorry", "let me redo", "let me do that again", "let me try that again", "start over", "scratch that",
                       "one more time", "take two", "let me say that again", "try again", "redo that", "again"]

    static func retakes(_ c: Context) -> [CleanUpItem] {
        let words = c.input.words
        guard words.count >= 6 else { return [] }
        // Phrases: runs of words split at gaps of `phraseGap` or more.
        var phrases: [[Int]] = [[0]]
        for i in 1..<words.count {
            if words[i].range.start - words[i - 1].range.end >= c.o.phraseGap { phrases.append([i]) } else { phrases[phrases.count - 1].append(i) }
        }
        func text(_ p: [Int]) -> [String] { p.map { normalize(words[$0].text) }.filter { !$0.isEmpty } }
        func range(_ p: [Int]) -> TimeRange { TimeRange(start: words[p[0]].range.start, end: words[p[p.count - 1]].range.end) }
        var out: [CleanUpItem] = []
        var used = Set<Int>()
        for i in 0..<phrases.count where !used.contains(i) {
            let a = text(phrases[i])
            guard a.count >= 3 else { continue }
            let ra = range(phrases[i])
            for j in (i + 1)..<min(phrases.count, i + 4) {
                let rb = range(phrases[j])
                guard rb.start - ra.end <= c.o.retakeWindow else { break }
                let b = text(phrases[j])
                guard b.count >= 3 else { continue }
                let opening = a.prefix(3) == b.prefix(3)
                let similarity = wordSimilarity(a, b)
                guard opening || similarity >= c.o.retakeSimilarity else { continue }
                // The earlier take and everything up to the later one goes; cue phrases may sit in either.
                let between = phrases[(i + 1)..<j].flatMap { text($0) }
                let cue = hasCue(Array(a.suffix(5)) + between + Array(b.prefix(4)))
                let cutStart = c.frameSnap(c.quietPoint(near: ra.start - 0.1, reach: 0.1,
                                                        bounds: TimeRange(start: ra.start - 0.3, end: ra.start)))
                let cutEnd = c.frameSnap(c.quietPoint(near: rb.start - 0.12, reach: 0.08,
                                                      bounds: TimeRange(start: rb.start - 0.3, end: rb.start - 0.05)))
                guard cutEnd - cutStart >= 0.3 else { continue }
                let cut = TimeRange(start: max(0, cutStart), end: cutEnd)
                // A click or key in the cut take may change what the later take shows: suggest only.
                let changesUI = c.inputs.contains { $0.start < cut.end && $0.end > cut.start }
                // The text already matches (opening words or similarity); a cue phrase is what makes it a retake.
                var confidence = 0.6 + (cue ? 0.25 : 0) + (opening && similarity >= c.o.retakeSimilarity ? 0.05 : 0)
                if let change = c.screenChange(in: cut) { confidence += change < 0.05 ? 0.05 : -0.2 }
                if !(cue && (opening || similarity >= c.o.retakeSimilarity)) || changesUI { confidence = min(confidence, 0.7) }
                out.append(CleanUpItem(kind: .retake, range: ra, cut: cut,
                                       reason: "retake: kept the later take (“\(words[phrases[j][0]].text) …”)", confidence: confidence))
                used.insert(j)
                break
            }
        }
        return out
    }

    // MARK: - Applying

    /// Adds the report's applied items to the edit (cuts to `cuts`, speed-ups as `cleanup` speed segments) and
    /// records them; the report's suggestions replace the previous run's.
    public static func apply(_ report: CleanUpReport, to edit: inout EditDocument) {
        for item in report.applied { add(item, to: &edit) }
        edit.cleanUp.suggestions = report.suggestions.filter { s in !edit.cleanUp.applied.contains { $0.editRange.overlaps(s.editRange) } }
    }

    static func add(_ item: CleanUpItem, to edit: inout EditDocument) {
        var item = item
        if let cut = item.cut {
            edit.cuts.append(cut)
        } else if let rate = item.rate {
            let id = "cu" + String(item.id.hashValueStable, radix: 36)
            edit.speed.set(item.range, rate: rate, source: .cleanUp, id: id)
            item.speedID = id
        } else { return }
        edit.cleanUp.applied.append(item)
        edit.cleanUp.applied.sort { $0.range.start < $1.range.start }
    }

    /// Removes an item's cut or speed-up from the edit, if it is still exactly as Clean Up made it.
    static func remove(_ item: CleanUpItem, from edit: inout EditDocument) {
        if let cut = item.cut, let i = edit.cuts.firstIndex(of: cut) {
            edit.cuts.remove(at: i)
        } else if let id = item.speedID {
            edit.speed.segments.removeAll { $0.id == id && $0.source == .cleanUp }
        }
    }

    /// Takes the whole of Clean Up out of the edit: every applied cut and speed-up, the suggestions and the
    /// restored list. Cuts and speed segments changed by hand since stay.
    public static func undoAll(_ edit: inout EditDocument) {
        for item in edit.cleanUp.applied { remove(item, from: &edit) }
        edit.cleanUp = CleanUpRecord()
    }

    /// Puts one applied item back (its moment plays again) and remembers it, so a later run leaves it alone.
    @discardableResult
    public static func restore(_ id: String, in edit: inout EditDocument) -> Bool {
        guard let i = edit.cleanUp.applied.firstIndex(where: { $0.id == id }) else { return false }
        let item = edit.cleanUp.applied.remove(at: i)
        remove(item, from: &edit)
        edit.cleanUp.restored.append(.init(kind: item.kind, range: item.range))
        return true
    }

    /// Applies a suggestion.
    @discardableResult
    public static func accept(_ id: String, in edit: inout EditDocument) -> Bool {
        guard let i = edit.cleanUp.suggestions.firstIndex(where: { $0.id == id }) else { return false }
        let item = edit.cleanUp.suggestions.remove(at: i)
        add(item, to: &edit)
        return true
    }

    /// Drops a suggestion; a later run won't suggest it again.
    @discardableResult
    public static func dismiss(_ id: String, in edit: inout EditDocument) -> Bool {
        guard let i = edit.cleanUp.suggestions.firstIndex(where: { $0.id == id }) else { return false }
        let item = edit.cleanUp.suggestions.remove(at: i)
        edit.cleanUp.restored.append(.init(kind: item.kind, range: item.range))
        return true
    }

    /// "1:12 shorter · 9 pauses · 6 ums · 1 retake · 3 speed-ups · 2 suggestions".
    public static func summary(applied: [CleanUpItem], suggestions: Int) -> String {
        var parts: [String] = []
        let saved = applied.reduce(0) { $0 + $1.savedSeconds }
        if saved >= 0.5 { parts.append("\(clock(saved)) shorter") }
        let groups: [(CleanUpItem.Kind, String, String)] = [
            (.pause, "pause", "pauses"), (.filler, "um", "ums"), (.retake, "retake", "retakes"), (.speedUp, "speed-up", "speed-ups"),
        ]
        for (kind, one, many) in groups {
            let n = applied.filter { $0.kind == kind }.count
            if n > 0 { parts.append("\(n) \(n == 1 ? one : many)") }
        }
        let dead = applied.filter { $0.kind == .deadStart || $0.kind == .deadEnd }.count
        if dead > 0 { parts.append(dead == 2 ? "start and end trimmed" : "dead \(applied.contains { $0.kind == .deadStart } ? "start" : "end") trimmed") }
        if suggestions > 0 { parts.append("\(suggestions) suggestion\(suggestions == 1 ? "" : "s")") }
        return parts.isEmpty ? "Nothing to clean up" : parts.joined(separator: " · ")
    }

    // MARK: - Text helpers

    static func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "'" }
            .map(String.init).joined()
    }

    static func endsSentence(_ s: String) -> Bool {
        guard let last = s.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!…".contains(last)
    }

    /// Vowel groups, at least 1: a rough syllable count for how long a word should take.
    static func syllables(_ s: String) -> Int {
        var n = 0, inVowel = false
        for ch in s { let v = "aeiouy".contains(ch); if v && !inVowel { n += 1 }; inVowel = v }
        return max(1, n)
    }

    /// Longest common subsequence of words over the longer phrase's length.
    static func wordSimilarity(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var row = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() { row[j + 1] = x == y ? prev[j] + 1 : max(prev[j + 1], row[j]) }
            prev = row
        }
        return Double(prev[b.count]) / Double(max(a.count, b.count))
    }

    static func hasCue(_ words: [String]) -> Bool {
        let text = " " + words.joined(separator: " ") + " "
        return cues.contains { text.contains(" \($0) ") }
    }

    static func seconds(_ s: Double) -> String { String(format: "%.1f s", s) }

    static func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 60 ? String(format: "%d:%02d", t / 60, t % 60) : "\(t) s"
    }
}

/// A voiced stretch at the start of a word, cut off from the rest of it by a dip: where a folded-in "um" sits.
struct FillerIsland {
    var voice: TimeRange
    var dip: TimeRange
    /// How far the dip falls below the island's peak, in dB.
    var depth: Float
    /// Whether the dip is below the silence threshold.
    var dipQuiet: Bool

    static func find(in word: TimeRange, envelope env: AudioEnvelope, threshold: Float) -> FillerIsland? {
        let idx = env.indices(word)
        guard idx.count >= 12 else { return nil }
        let lv = idx.map { env.levels[$0] }
        // Voiced = within 20 dB of the word's loudest window and above the threshold.
        let peak = lv.max() ?? -160
        let voicedLevel = max(threshold, peak - 20)
        var i = 0
        while i < lv.count, lv[i] < voicedLevel { i += 1 }
        let islandStart = i
        var islandPeak: Float = -160
        while i < lv.count, lv[i] >= voicedLevel { islandPeak = max(islandPeak, lv[i]); i += 1 }
        let islandEnd = i
        let islandSec = Double(islandEnd - islandStart) * env.window
        guard islandSec >= 0.15, islandSec <= 0.8, islandEnd < lv.count else { return nil }
        // The dip: windows at least 10 dB under the island's peak, at least 60 ms, then voice again.
        var j = islandEnd
        while j < lv.count, lv[j] <= islandPeak - 10 { j += 1 }
        let dipSec = Double(j - islandEnd) * env.window
        guard dipSec >= 0.06, j < lv.count, lv[j...].contains(where: { $0 >= voicedLevel }) else { return nil }
        let dipLevels = lv[islandEnd..<j]
        let dipMax = dipLevels.max() ?? -160
        func t(_ k: Int) -> Double { env.origin + Double(idx.lowerBound + k) * env.window }
        return FillerIsland(voice: TimeRange(start: t(islandStart), end: t(islandEnd)), dip: TimeRange(start: t(islandEnd), end: t(j)),
                            depth: islandPeak - dipMax, dipQuiet: dipMax < threshold)
    }
}

extension String {
    /// A hash that is the same on every run (Swift's `hashValue` is seeded per process).
    var hashValueStable: UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }
}
